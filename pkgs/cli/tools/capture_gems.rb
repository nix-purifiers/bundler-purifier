# SPDX-License-Identifier: MIT
# Capture the target Bundler SDK's actual runtime graph after native builds.
require "rubygems"
gem "bundler", "= 0.3.1" if !defined?(Gem::VERSION) && defined?(Gem::RubyGemsVersion) && Gem::RubyGemsVersion == "1.0.1"
require "bundler"
require File.expand_path("ruby_config", File.dirname(__FILE__))
require "rubygems/package"
require "json"
require "fileutils"
require "tmpdir"
require "rbconfig"

def with_capture_directory
  if Dir.respond_to?(:mktmpdir)
    Dir.mktmpdir("bundler-capture-") { |directory| yield directory }
  else
    # Ruby 1.8.4's tmpdir has no mktmpdir. Create the owned directory
    # atomically and retry collisions without touching existing entries.
    directory = nil
    100.times do
      candidate = File.join(Dir.tmpdir, "bundler-capture-#{Process.pid}-#{rand(0x7fffffff)}")
      begin
        Dir.mkdir(candidate, 0700)
        directory = candidate
        break
      rescue Errno::EEXIST
      end
    end
    raise "bundler-purifier: could not create capture directory" unless directory
    begin
      yield directory
    ensure
      FileUtils.rm_rf(directory)
    end
  end
end

def copy_runtime_file(input, target)
  FileUtils.mkdir_p(File.dirname(target))
  File.chmod(File.stat(target).mode | 0200, target) if File.exist?(target)
  FileUtils.cp(input, target)
  File.chmod(File.stat(input).mode & 0777, target)
end

output = File.expand_path(ARGV.fetch(0))
FileUtils.mkdir_p(output)
provided = JSON.parse(ENV.fetch("BUNDLER_PURIFIER_INPUT_VIEWS", "[]")).map do |view|
  JSON.parse(File.read(view.fetch("catalog"))).fetch("packages").map { |entry| [entry.fetch("name"), entry.fetch("version")] }
end.inject([]) { |all, entries| all.concat(entries) }
owned = JSON.parse(ENV.fetch("BUNDLER_PURIFIER_OWN_ARCHIVES", "[]")).inject({}) do |result, archive|
  spec = if Gem::Package.respond_to?(:new)
    Gem::Package.new(archive).spec
  else
    require "rubygems/format"
    Gem::Format.from_file_by_path(archive).spec
  end
  result[spec.name] = spec.files
  result
end
roots = JSON.parse(ENV.fetch("BUNDLER_PURIFIER_PROJECT_ROOTS", "[]"))
native_v03 = !defined?(Bundler::Definition) && defined?(Bundler::ManifestFile) && Bundler::VERSION == "0.5.0" && defined?(Gem::RubyGemsVersion) && Gem::RubyGemsVersion == "1.0.1" && Gem.loaded_specs["bundler"].version.to_s == "0.3.1"
native_prelock = native_v03 || (!defined?(Bundler::Definition) && defined?(Bundler::Bundle) && Bundler::Bundle.respond_to?(:load))
# Gem101's dependency model has no development/runtime discriminator.
runtime_dependencies = lambda { |spec| native_v03 ? spec.dependencies : spec.runtime_dependencies }
if roots.empty?
  roots = if native_prelock
    owned.keys
  else
    Bundler.definition.dependencies.reject do |dependency|
      dependency.groups.all? { |group| [:development, :test, :doc].include?(group) }
    end.map { |dependency| dependency.name }
  end
end
roots -= ["bundler"]
File.open(File.join(output, "roots.json"), "wb") { |file| file.write(JSON.dump(roots.sort) + "\n") }
legacy_environment = !native_prelock && !Bundler::Definition.respond_to?(:build)
native_sources = {}
prelock_own_sources = {}
runtime_specs = if native_prelock
  environment = File.join(Dir.pwd, "vendor", "gems", native_v03 ? "environments/default.rb" : "environment.rb")
  raise "bundler-purifier: native pre-lockfile environment missing" unless File.file?(environment)
  require environment
  selected = Bundler.instance_variable_get(:@bundled_specs)
  raise "bundler-purifier: native pre-lockfile specifications missing" unless selected.is_a?(Hash)
  own_specs = JSON.parse(ENV.fetch("BUNDLER_PURIFIER_OWN_ARCHIVES", "[]")).map do |archive|
    require "rubygems/format"
    spec = Gem::Format.from_file_by_path(archive).spec
    directories = JSON.parse(ENV.fetch("BUNDLER_PURIFIER_PROJECT_DIRECTORIES", "{}"))
    prelock_own_sources[spec.name] = File.expand_path(directories.fetch(spec.name, "."), Dir.pwd)
    spec
  end
  # Root gemspecs are a separate domain in this SDK. Its immutable JSON codec
  # is an identity-bound runtime component even for an empty native bundle.
  Gem.loaded_specs.values + selected.values + own_specs
elsif !legacy_environment
  Bundler.load.specs
else
  # Native setup can load the generated environment without evaluating the
  # facade. Apply declared input bindings to archive dependency metadata.
  if ENV["BUNDLER_PURIFIER_INPUT_DATA"] && !defined?(PurifierGemInputs)
    require File.expand_path("rubygems_inputs", File.dirname(__FILE__))
  end
  Bundler.definition.actual_dependencies.each { |dependency| native_sources[dependency.name] = dependency.source }
  runtime = Bundler.load
  unless Bundler.respond_to?(:env_file)
    raise "bundler-purifier: native runtime unavailable" unless runtime.is_a?(Bundler::Runtime) &&
      runtime.respond_to?(:rb_lock_file, true) && runtime.respond_to?(:gemfile_fingerprint, true)
    environment = runtime.send(:rb_lock_file)
    raise "bundler-purifier: native environment missing; run native install and lock" unless environment.file?
    fingerprint = runtime.send(:gemfile_fingerprint)
    require environment.to_s
    raise "bundler-purifier: native environment SDK mismatch" unless Bundler::LOCKED_BY == Bundler::VERSION
    raise "bundler-purifier: native environment fingerprint stale" unless Bundler::FINGERPRINT == fingerprint
  end
  raise "bundler-purifier: native environment missing; run native install and lock" unless defined?(Bundler::SPECS)
  Bundler::SPECS
end
specs = runtime_specs.to_a.inject({}) { |result, spec| result[spec.name] = spec; result }
selected = {}
visit = lambda do |name|
  return if selected.key?(name) || name == "bundler" || !specs.key?(name)
  selected[name] = specs.fetch(name)
  runtime_dependencies.call(specs.fetch(name)).each { |dependency| visit.call(dependency.name) }
end
(roots + owned.keys).uniq.each { |name| visit.call(name) }
archives = []
intrinsics = []
selected.values.each do |original|
  next if original.name == "bundler" || provided.include?([original.name, original.version.to_s])
  if !prelock_own_sources.key?(original.name) && (original.full_gem_path.index(PurifierRubyConfig.values.fetch("prefix") + "/") == 0)
    intrinsics << { "name" => original.name, "version" => original.version.to_s,
                    "sdk" => PurifierRubyConfig.values.fetch("prefix"), "ruby" => RUBY_VERSION,
                    "system" => Gem::Platform.local.to_s,
                    "dependencies" => runtime_dependencies.call(original).map { |dependency| { "name" => dependency.name, "requirement" => (native_v03 ? dependency.version_requirements : dependency.instance_variable_get(:@requirement)).to_s } } }
    next
  end
  with_capture_directory do |directory|
    origin = native_prelock ? nil : (original.source || native_sources[original.name])
    local = native_prelock ? prelock_own_sources.key?(original.name) : origin.is_a?(Bundler::Source::Path)
    source = if native_prelock && local
      prelock_own_sources.fetch(original.name)
    else
      legacy_environment && local ? origin.path.to_s : original.full_gem_path
    end
    files = local ? owned.fetch(original.name, original.files) : original.files
    # The 0.9 generated environment expands require_paths in native specs.
    # Recover paths inside this actual gem; retain the archive boundary.
    relative_paths = lambda do |paths|
      paths.map do |path|
        if path == source
          "."
        elsif (path.index(source + "/") == 0)
          path.sub(/\A#{Regexp.escape(source + "/")}/, "")
        else
          path
        end
      end
    end
    require_paths = relative_paths.call(original.require_paths)
    runtime_paths = (require_paths + relative_paths.call([original.bindir])).reject do |path|
      (path.index("/") == 0) || path == "." || path.split("/").include?("..")
    end
    files += Dir.chdir(source) do
      runtime_paths.map { |path| Dir.glob(File.join(path, "**", "*"), File::FNM_DOTMATCH) }.inject([]) { |all, entries| all.concat(entries) }
    end
    files.uniq.each do |relative|
      next if (relative.index("/") == 0) || (relative.split("/") & ["..", ".git"]).any?
      input = File.join(source, relative)
      next unless File.file?(input)
      target = File.join(directory, relative)
      FileUtils.mkdir_p(File.dirname(target))
      copy_runtime_file(input, target)
    end
    if original.respond_to?(:default_gem?) && original.default_gem?
      # Default gems live in Ruby's stdlib/architecture directories, rather
      # than the otherwise empty gems/<name>/lib tree.
      original.files.grep(/\.(rb|so|bundle|dll)$/).each do |relative|
        roots = [PurifierRubyConfig.values.fetch("rubylibdir"), PurifierRubyConfig.values.fetch("archdir")]
        inputs = roots.map do |root|
          exact = File.join(root, relative)
          File.file?(exact) ? [exact] : Dir.glob(File.join(root, "**", relative))
        end.inject([]) { |all, entries| all.concat(entries) }.uniq
        inputs.each do |input|
          sdk_root = roots.find { |root| (input.index(root + "/") == 0) }
          target = File.join(directory, "lib", input.sub(/\A#{Regexp.escape(sdk_root + "/")}/, ""))
          FileUtils.mkdir_p(File.dirname(target))
          copy_runtime_file(input, target)
        end
      end
      original.extensions.each do |extension|
        prefix = extension.sub(/\Aext\//, "").sub(/\/extconf\.rb\z/, "")
        arch = PurifierRubyConfig.values.fetch("archdir")
        Dir.glob([File.join(arch, prefix + ".{so,bundle,dll}"), File.join(arch, prefix, "**", "*.{so,bundle,dll}")]).each do |input|
          target = File.join(directory, "lib", input.sub(/\A#{Regexp.escape(arch + "/")}/, ""))
          FileUtils.mkdir_p(File.dirname(target))
          copy_runtime_file(input, target)
        end
      end
    end
    native = !original.extensions.empty?
    if original.respond_to?(:extension_dir) && File.directory?(original.extension_dir)
      Dir.glob(File.join(original.extension_dir, "**", "*"), File::FNM_DOTMATCH).each do |input|
        next unless File.file?(input)
        relative = input.sub(/\A#{Regexp.escape(original.extension_dir + "/")}/, "")
        next if relative == "gem.build_complete"
        target = File.join(directory, "lib", relative)
        FileUtils.mkdir_p(File.dirname(target))
        copy_runtime_file(input, target)
      end
    end
    spec = if legacy_environment && !original.instance_of?(Gem::Specification)
      # This SDK wraps Git/path specs in a Bundler subclass. Archive only
      # native RubyGems attributes so ordinary consumers need no SDK class.
      Gem::Specification.new do |copy|
        Gem::Specification.attribute_names.each do |attribute|
          if attribute.to_s == "dependencies"
            copy.dependencies.concat(original.dependencies.map do |dependency|
              Gem::Dependency.new(dependency.name, dependency.requirement, dependency.type)
            end)
          else
            copy.send("#{attribute}=", original.send(attribute))
          end
        end
      end
    else
      original.dup
    end
    spec.extensions = []
    spec.require_paths = require_paths.reject { |path| (path.index("/") == 0) }
    spec.require_paths = ["lib"] if spec.require_paths.empty?
    if native
      spec.platform = Gem::Platform.local
      # Legacy installers include patchlevel in Gem.ruby_version, while
      # resolver APIs can use bare RUBY_VERSION for the same release point.
      # Retain exact preview requirements until their ABI is tested separately.
      spec.required_ruby_version = if native_v03
        Gem::Requirement.new("~> #{RUBY_VERSION}.0")
      elsif Gem.ruby_version.prerelease?
        Gem::Requirement.new("= #{Gem.ruby_version}")
      else
        next_release = Gem::Version.new(RUBY_VERSION + ".0").bump
        requirement = Gem::Requirement.new([">= #{RUBY_VERSION}", "< #{next_release}"])
        if spec.respond_to?(:ruby_code, true)
          begin
            # The native installed-gemspec serializer in older RubyGems
            # joins both clauses into one invalid constructor argument.
            eval(spec.send(:ruby_code, requirement))
          rescue ArgumentError
            # Preserve stable/patchlevel bounds; also exclude previews of
            # the next, unverified ABI. Newer serializers keep their form.
            requirement = Gem::Requirement.new("~> #{RUBY_VERSION}.0")
          end
        end
        requirement
      end
      if spec.respond_to?(:metadata)
        spec.metadata = spec.metadata.merge("nix-purifier-ruby-engine" => (defined?(RUBY_ENGINE) ? RUBY_ENGINE : "ruby"),
                                           "nix-purifier-ruby-version" => RUBY_VERSION)
      end
    end
    spec.cert_chain = []
    spec.extra_rdoc_files = spec.extra_rdoc_files.select { |path| File.file?(File.join(directory, path)) }
    spec.test_files = spec.test_files.select { |path| File.file?(File.join(directory, path)) }
    spec.files = Dir.chdir(directory) { Dir.glob("**/*", File::FNM_DOTMATCH).select { |path| File.file?(path) } }
    filename = Dir.chdir(directory) do
      if Gem::Package.respond_to?(:build)
        Gem::Package.build(spec)
      else
        require "rubygems/builder"
        Gem::Builder.new(spec).build
      end
    end
    FileUtils.cp(File.join(directory, filename), File.join(output, filename))
    archives << filename
  end
end
File.open(File.join(output, "archives.json"), "wb") { |file| file.write(JSON.dump(archives.sort) + "\n") }

File.open(File.join(output, "intrinsics.json"), "wb") { |file| file.write(JSON.dump(intrinsics.sort_by { |entry| entry.fetch("name") }) + "\n") }
