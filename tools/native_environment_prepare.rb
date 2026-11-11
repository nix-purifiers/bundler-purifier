# SPDX-License-Identifier: MIT
# Capture and offline candidate regeneration. Activation and working-state
# receipts belong to a separate validation step; this helper never activates a
# captured snapshot. Regeneration must run in a Nix network-isolated builder.
require "fileutils"
require "tempfile"
require_relative "native_environment_sdk"

module PurifierNativeEnvironmentPrepare
  CONTRACT = PurifierNativeEnvironment
  SDK = PurifierNativeEnvironmentSDK

  def self.snapshot(project, relative)
    CONTRACT.path!(relative)
    path = File.realpath(File.join(project, relative))
    CONTRACT.reject!("native evidence escapes project role") unless path.start_with?(project + "/")
    CONTRACT.reject!("native snapshot exceeds size limit") unless File.file?(path) && File.size(path) <= CONTRACT::MAX_SNAPSHOT
    bytes = File.binread(path)
    {"path" => relative, "size" => bytes.bytesize, "sha256" => CONTRACT.hash_bytes(bytes),
     "base64" => Base64.strict_encode64(bytes)}.tap { |record| CONTRACT.snapshot!(record) }
  end

  def self.with_bindings(bindings, operation)
    CONTRACT.bindings!(bindings)
    return yield(SDK.clean_environment, []) if bindings.empty?
    Tempfile.create(["bundler-native-bindings-", ".tsv"]) do |file|
      bindings.sort_by { |binding| binding.fetch("name") }.each do |binding|
        file.write(binding.fetch("name") + "\t" + binding.fetch("version") + "\n")
      end
      file.flush
      environment = SDK.clean_environment(
        "BUNDLER_PURIFIER_NATIVE_BINDINGS" => file.path,
        "BUNDLER_PURIFIER_NATIVE_OPERATION" => operation)
      yield(environment, ["-r", File.join(__dir__, "native_environment_bindings.rb")])
    end
  end

  def self.capture(project, sdk, identity: nil, project_gemspecs: [], bindings: [])
    project = File.realpath(project)
    CONTRACT.reject!("ambiguous Gemfile.lock for pre-lockfile SDK") if File.exist?(File.join(project, "Gemfile.lock")) || File.symlink?(File.join(project, "Gemfile.lock"))
    identity ||= SDK.attest(sdk)
    observer = File.join(__dir__, "native_environment_observe.rb")
    observation = with_bindings(bindings, "observe") do |environment, prefix|
      JSON.parse(SDK.run(File.join(sdk, "bin/ruby"), *prefix, observer, project, env: environment, cwd: project))
    end
    CONTRACT.exact!(observation, %w[packages rootRequirements generatedPaths], "native environment observation")
    manifests = (["Gemfile"] + project_gemspecs).uniq.sort.map { |path| snapshot(project, path) }
    result = {"format" => "bundler-native-environment", "schemaVersion" => 1,
              "interface" => "environment-v08", "nativeLockFile" => nil,
              "contexts" => ["default"], "sdk" => identity, "manifests" => manifests,
              "bindingAlgorithm" => "declared-runtime-requirements-v1", "bindings" => bindings,
              "snapshots" => observation.fetch("generatedPaths").map { |path| snapshot(project, path) },
              "packages" => observation.fetch("packages"), "rootRequirements" => observation.fetch("rootRequirements")}
    CONTRACT.validate!(result)
  end

  def self.project_specs(project, native_project, sdk, paths, bindings: [])
    project = File.realpath(project)
    paths.each { |path| snapshot(project, path) }
    script = File.join(__dir__, "native_environment_project_specs.rb")
    environment = File.join(native_project, "vendor/gems/environment.rb")
    with_bindings(bindings, "runtime") do |context, prefix|
      JSON.parse(SDK.run(File.join(sdk, "bin/ruby"), *prefix, script, project, environment, *paths,
                        env: context, cwd: project))
    end
  end

  # Initial lock resolution also uses an owned arena. SDK writes never touch
  # the developer's existing bundle; available archives retain exact bytes.
  def self.resolve(project, sdk, available_archives, destination, bindings: [], project_gemspecs: [])
    project = File.realpath(project)
    CONTRACT.reject!("ambiguous Gemfile.lock for pre-lockfile SDK") if File.exist?(File.join(project, "Gemfile.lock")) || File.symlink?(File.join(project, "Gemfile.lock"))
    identity = SDK.attest(sdk)
    CONTRACT.bindings!(bindings)
    manifests = (["Gemfile"] + project_gemspecs).uniq.sort.map { |path| snapshot(project, path) }
    CONTRACT.list!(available_archives, "native available archive")
    verified = {}
    available_archives.each do |entry|
      CONTRACT.exact!(entry, %w[path sha256], "native available archive")
      CONTRACT.digest!(entry.fetch("sha256"))
      path = File.realpath(entry.fetch("path"))
      CONTRACT.reject!("native available archive is not regular") unless File.file?(path)
      CONTRACT.reject!("native available archive bytes conflict with declared input") unless CONTRACT.hash_file(path) == entry.fetch("sha256")
      name = File.basename(path)
      CONTRACT.reject!("native available archive needs its genuine .gem filename") unless name.end_with?(".gem")
      CONTRACT.reject!("native available archives have conflicting destinations") if verified.key?(name) && verified.fetch(name).fetch("sha256") != entry.fetch("sha256")
      verified[name] = {"path" => path, "sha256" => entry.fetch("sha256")}
    end
    destination = File.join(File.realpath(File.dirname(destination)), File.basename(destination))
    CONTRACT.reject!("native resolution destination already exists") if File.exist?(destination) || File.symlink?(destination)
    Dir.mkdir(destination, 0700)
    manifests.each do |record|
      path = File.join(destination, record.fetch("path"))
      FileUtils.mkdir_p(File.dirname(path), mode: 0700)
      File.binwrite(path, Base64.strict_decode64(record.fetch("base64")))
    end
    with_bindings(bindings, "resolve") do |environment, prefix|
      command = prefix.empty? ? [File.join(sdk, "bin/gem")] : [File.join(sdk, "bin/ruby"), *prefix, SDK.gem_script(sdk)]
      verified.each_value { |entry| SDK.run(*command, "bundle", "--cache", entry.fetch("path"), env: environment, cwd: destination) }
      SDK.run(*command, "bundle", "--cached", env: environment, cwd: destination)
    end
    result = capture(destination, sdk, identity: identity, project_gemspecs: project_gemspecs, bindings: bindings)
    allowed = verified.values.map { |entry| entry.fetch("sha256") }
    CONTRACT.reject!("native resolution selected archive bytes outside verified inputs") unless result.fetch("packages").all? { |package| allowed.include?(package.fetch("archiveHash")) }
    result
  end

  def self.regenerate(expected, sdk, archives, destination, closure_paths: nil)
    CONTRACT.validate!(expected)
    identity = SDK.attest(sdk, closure_paths: closure_paths)
    CONTRACT.reject!("native replay SDK differs from capture") unless SDK.normalized_identity(identity) == SDK.normalized_identity(expected.fetch("sdk"))
    packages = expected.fetch("packages")
    CONTRACT.reject!("native replay archive set differs from capture") unless archives.is_a?(Hash) && archives.keys.sort == packages.map { |package| package.fetch("name") }.sort
    verified = packages.to_h do |package|
      archive = File.realpath(archives.fetch(package.fetch("name")))
      CONTRACT.reject!("native replay archive is not regular") unless File.file?(archive)
      CONTRACT.reject!("native replay archive bytes differ from capture") unless CONTRACT.hash_file(archive) == package.fetch("archiveHash")
      [package.fetch("name"), archive]
    end
    destination = File.join(File.realpath(File.dirname(destination)), File.basename(destination))
    CONTRACT.reject!("native regeneration destination already exists") if File.exist?(destination) || File.symlink?(destination)
    Dir.mkdir(destination, 0700)
    expected.fetch("manifests").each do |record|
      path = File.join(destination, record.fetch("path"))
      FileUtils.mkdir_p(File.dirname(path), mode: 0700)
      File.binwrite(path, Base64.strict_decode64(record.fetch("base64")))
    end
    # Cache and resolve through the genuine plugin. --cached selects only
    # native local sources; Nix supplies the network isolation for Ruby code.
    with_bindings(expected.fetch("bindings"), "resolve") do |environment, prefix|
      command = prefix.empty? ? [File.join(sdk, "bin/gem")] : [File.join(sdk, "bin/ruby"), *prefix, SDK.gem_script(sdk)]
      verified.each_value do |archive|
        SDK.run(*command, "bundle", "--cache", archive, env: environment, cwd: destination)
      end
      SDK.run(*command, "bundle", "--cached", env: environment, cwd: destination)
    end
    fresh = capture(destination, sdk, identity: identity,
                    project_gemspecs: expected.fetch("manifests").map { |record| record.fetch("path") } - ["Gemfile"],
                    bindings: expected.fetch("bindings"))
    CONTRACT.compare_observation!(expected, fresh)
    fresh
  end
end

if __FILE__ == $0
  mode = ARGV.shift
  case mode
  when "capture"
    raise "usage: native_environment_prepare.rb capture PROJECT SDK [BINDINGS]" unless ARGV.size.between?(2, 3)
    project, sdk, binding_file = ARGV
    bindings = binding_file ? JSON.parse(File.binread(binding_file, 1048577), object_class: PurifierNativeEnvironment::UniqueObject) : []
    result = PurifierNativeEnvironmentPrepare.capture(project, sdk, bindings: bindings)
  when "regenerate"
    raise "usage: native_environment_prepare.rb regenerate RECORD SDK ARCHIVES DESTINATION [CLOSURE-PATHS]" unless ARGV.size.between?(4, 5)
    record, sdk, archive_file, destination, closure_file = ARGV
    expected = PurifierNativeEnvironment.parse(File.binread(record, PurifierNativeEnvironment::MAX_DOCUMENT + 1))
    archive_bytes = File.binread(archive_file, PurifierNativeEnvironment::MAX_DOCUMENT + 1)
    PurifierNativeEnvironment.reject!("archive transport map exceeds size limit") if archive_bytes.bytesize > PurifierNativeEnvironment::MAX_DOCUMENT
    archives = JSON.parse(archive_bytes, object_class: PurifierNativeEnvironment::UniqueObject)
    closure_paths = closure_file ? File.readlines(closure_file, chomp: true).reject(&:empty?) : nil
    result = PurifierNativeEnvironmentPrepare.regenerate(expected, sdk, archives, destination, closure_paths: closure_paths)
  else
    raise "expected capture or regenerate"
  end
  puts JSON.generate(PurifierNativeEnvironment.canonical(result))
end
