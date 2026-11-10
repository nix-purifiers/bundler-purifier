# SPDX-License-Identifier: MIT
# Capture the target Bundler SDK's actual runtime graph after native builds.
require "bundler"
require "rubygems/package"
require "json"
require "fileutils"
require "tmpdir"
require "rbconfig"

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
end.flatten(1)
owned = Hash[JSON.parse(ENV.fetch("BUNDLER_PURIFIER_OWN_ARCHIVES", "[]")).map do |archive|
  spec = if Gem::Package.respond_to?(:new)
    Gem::Package.new(archive).spec
  else
    require "rubygems/format"
    Gem::Format.from_file_by_path(archive).spec
  end
  [spec.name, spec.files]
end]
roots = JSON.parse(ENV.fetch("BUNDLER_PURIFIER_PROJECT_ROOTS", "[]"))
if roots.empty?
  roots = Bundler.definition.dependencies.reject do |dependency|
    dependency.groups.all? { |group| [:development, :test, :doc].include?(group) }
  end.map(&:name)
end
roots -= ["bundler"]
File.open(File.join(output, "roots.json"), "wb") { |file| file.write(JSON.dump(roots.sort) + "\n") }
specs = Hash[Bundler.load.specs.to_a.map { |spec| [spec.name, spec] }]
selected = {}
visit = lambda do |name|
  return if selected.key?(name) || name == "bundler" || !specs.key?(name)
  selected[name] = specs.fetch(name)
  specs.fetch(name).runtime_dependencies.each { |dependency| visit.call(dependency.name) }
end
(roots + owned.keys).uniq.each { |name| visit.call(name) }
archives = []
intrinsics = []
selected.values.each do |original|
  next if original.name == "bundler" || provided.include?([original.name, original.version.to_s])
  if original.full_gem_path.start_with?(RbConfig::CONFIG.fetch("prefix") + "/")
    intrinsics << { "name" => original.name, "version" => original.version.to_s,
                    "sdk" => RbConfig::CONFIG.fetch("prefix"), "ruby" => RUBY_VERSION,
                    "system" => Gem::Platform.local.to_s,
                    "dependencies" => original.runtime_dependencies.map { |dependency| { "name" => dependency.name, "requirement" => dependency.instance_variable_get(:@requirement).to_s } } }
    next
  end
  Dir.mktmpdir("bundler-capture-") do |directory|
    source = original.full_gem_path
    local = original.source.is_a?(Bundler::Source::Path)
    files = local ? owned.fetch(original.name, original.files) : original.files
    runtime_paths = (original.require_paths + [original.bindir]).reject do |path|
      path.start_with?("/") || path == "." || path.split("/").include?("..")
    end
    files += Dir.chdir(source) do
      runtime_paths.map { |path| Dir.glob(File.join(path, "**", "*"), File::FNM_DOTMATCH) }.flatten(1)
    end
    files.uniq.each do |relative|
      next if relative.start_with?("/") || (relative.split("/") & ["..", ".git"]).any?
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
        roots = [RbConfig::CONFIG.fetch("rubylibdir"), RbConfig::CONFIG.fetch("archdir")]
        inputs = roots.map do |root|
          exact = File.join(root, relative)
          File.file?(exact) ? [exact] : Dir.glob(File.join(root, "**", relative))
        end.flatten(1).uniq
        inputs.each do |input|
          sdk_root = roots.find { |root| input.start_with?(root + "/") }
          target = File.join(directory, "lib", input.sub(/\A#{Regexp.escape(sdk_root + "/")}/, ""))
          FileUtils.mkdir_p(File.dirname(target))
          copy_runtime_file(input, target)
        end
      end
      original.extensions.each do |extension|
        prefix = extension.sub(/\Aext\//, "").sub(/\/extconf\.rb\z/, "")
        arch = RbConfig::CONFIG.fetch("archdir")
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
    spec = original.dup
    spec.extensions = []
    spec.require_paths = original.require_paths.reject { |path| path.start_with?("/") }
    spec.require_paths = ["lib"] if spec.require_paths.empty?
    if native
      spec.platform = Gem::Platform.local
      # Legacy installers include patchlevel in Gem.ruby_version, while
      # resolver APIs can use bare RUBY_VERSION for the same release point.
      # Retain exact preview requirements until their ABI is tested separately.
      spec.required_ruby_version = if Gem.ruby_version.prerelease?
        Gem::Requirement.new("= #{Gem.ruby_version}")
      else
        next_release = Gem::Version.new(RUBY_VERSION + ".0").bump
        Gem::Requirement.new(">= #{RUBY_VERSION}", "< #{next_release}")
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
