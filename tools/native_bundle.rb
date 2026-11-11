# SPDX-License-Identifier: MIT
# Lend Bundler an input-aware Gemfile while preserving the user's manifest.
require "json"
require "tempfile"
require "fileutils"
require "uri"
require File.expand_path("repository_uri", File.dirname(__FILE__))

module PurifierNativeBundle
  # Selecting an executable does not activate its gem in a new Ruby
  # process. Activate before loading it so another visible Bundler cannot
  # silently replace the requested native SDK.
  def self.bundle_command(ruby, bundle, arguments)
    [ruby, File.join(File.dirname(__FILE__), "native_bundle_bootstrap.rb"), bundle] + arguments
  end

  # Ruby 1.8 has neither keyword arguments nor system's environment/chdir
  # options. Keep those changes in the child, as modern system does.
  def self.native_system(environment, arguments, options)
    return system(*([environment] + arguments + [options])) if defined?(Process.spawn)
    child = fork do
      begin
        environment.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
        Dir.chdir(options[:chdir]) if options[:chdir]
        STDOUT.reopen(options[:out]) if options[:out]
        exec(*arguments)
      rescue SystemCallError => error
        STDERR.puts(error.message)
        exit! 127
      end
    end
    Process.waitpid(child)
    $?.success?
  end

  def self.run(arguments, options)
    root, views, ruby, bundle = options.values_at(:root, :views, :ruby, :bundle)
    persist_lock = options.fetch(:persist_lock, false)
    yaml_lock = options.fetch(:lock_format, "text") == "yaml"
    env = options.fetch(:env, {})
    working_directory = ENV.fetch("BUNDLER_PURIFIER_WORKING_DIRECTORY", root)
    return native_system(env, bundle_command(ruby, bundle, arguments), :chdir => working_directory) if views.empty?

    command = arguments.find { |argument| !argument.start_with?("-") }
    env = env.merge("BUNDLER_PURIFIER_RUNTIME" => %w[exec console].include?(command) ? "1" : "0")
    packages = {}
    views.each do |view|
      catalog = JSON.parse(File.read(view.fetch("catalog")))
      entries = catalog.fetch("packages") + catalog.fetch("intrinsics", []).map { |entry| entry.merge("intrinsic" => true) }
      entries.each do |entry|
        name = entry.fetch("name")
        candidate = entry.merge("repository" => URI.parse("file://#{view.fetch('repository')}/").to_s)
        if packages.key?(name) && (
          packages[name].fetch("version") != candidate.fetch("version") ||
          !!packages[name]["intrinsic"] != !!candidate["intrinsic"] ||
          (candidate["intrinsic"] ? packages[name]["sdk"] != candidate["sdk"] : packages[name]["integrity"] != candidate["integrity"]))
          raise "bundler-purifier: conflicting Nix inputs for #{name}"
        end
        packages[name] = candidate
      end
    end
    input_data = Marshal.dump(packages).unpack("H*").first
    if (persistent = ENV["BUNDLER_PURIFIER_PERSISTENT_GEMFILE"])
      native_env = env.merge("BUNDLE_GEMFILE" => persistent,
                             "BUNDLER_PURIFIER_INPUT_DATA" => input_data)
      return native_system(native_env, bundle_command(ruby, bundle, arguments), :chdir => working_directory)
    end
    manifest = File.join(root, "Gemfile")
    original_lock = manifest + ".lock"
    facade = Tempfile.new([".bundler-purifier-", ".Gemfile"], root)
    facade_lock = yaml_lock ? nil : facade.path + ".lock"
    facade.write("require #{File.join(File.dirname(__FILE__), 'rubygems_inputs.rb').inspect}\n")
    facade.write("eval_gemfile #{manifest.inspect}\n")
    facade.close
    FileUtils.cp(original_lock, facade_lock) if facade_lock && File.file?(original_lock)
    native_env = env.merge("BUNDLE_GEMFILE" => facade.path,
                           "BUNDLER_PURIFIER_INPUT_VIEWS" => JSON.dump(views),
                           "BUNDLER_PURIFIER_ORIGINAL_GEMFILE" => manifest,
                           "BUNDLER_PURIFIER_INPUT_DATA" => input_data)
    unless command.nil? || %w[config lock update add remove install version help].include?(command)
      require "bundler"
      inspected_lock = yaml_lock ? original_lock : facade_lock
      locked_specs = if File.file?(inspected_lock)
        yaml_lock ? Bundler::Definition.from_lock(inspected_lock).actual_dependencies : Bundler::LockfileParser.new(File.read(inspected_lock)).specs
      else
        []
      end
      needs_binding = !File.file?(inspected_lock) || locked_specs.any? do |spec|
        next false unless (package = packages[spec.name])
        source = spec.source
        version_matches = yaml_lock ? spec.requirement == Gem::Requirement.new("= #{package.fetch('version')}") : spec.version.to_s == package.fetch("version")
        remotes = source.respond_to?(:remotes) ? source.remotes : (source.respond_to?(:uri) ? [source.uri] : [])
        !version_matches ||
          !source.is_a?(Bundler::Source::Rubygems) ||
          (package["intrinsic"] ? !remotes.empty? : !remotes.any? { |remote| PurifierRepositoryURI.identity(remote) == PurifierRepositoryURI.identity(package.fetch("repository")) })
      end
      if needs_binding
        commands = yaml_lock ? [["install"], ["lock"]] : [["lock", "--local"]]
        commands.each do |binding_command|
          return false unless native_system(native_env, bundle_command(ruby, bundle, binding_command), :chdir => root, :out => STDERR)
        end
      end
    end
    result = native_system(native_env, bundle_command(ruby, bundle, arguments), :chdir => working_directory)
    FileUtils.cp(facade_lock, original_lock) if result && persist_lock && facade_lock && File.file?(facade_lock)
    result
  ensure
    FileUtils.rm_f(facade_lock) if facade_lock
    facade.unlink if facade
  end
end
