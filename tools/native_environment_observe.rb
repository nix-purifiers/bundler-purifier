# SPDX-License-Identifier: MIT
# Run in a separate selected-SDK process after native offline regeneration.
# Keep syntax and APIs compatible with the original Ruby 1.8.4 runtime.
require "rubygems"
require "pathname"
require "digest/sha2"
require "find"

module PurifierEnvironmentObservation
  def self.fail!(message)
    raise "bundler-purifier: #{message}"
  end

  def self.within(root, path)
    real = File.realpath(path) if File.respond_to?(:realpath)
    real ||= Pathname.new(path).realpath.to_s
    prefix = root + File::SEPARATOR
    fail!("native selected path escapes owned workspace") unless real.index(prefix) == 0
    real[prefix.length..-1]
  end

  def self.dependencies(spec)
    spec.dependencies.map do |dependency|
      requirement = dependency.version_requirements
      clauses = requirement.requirements.map { |pair| pair[0].to_s + " " + pair[1].to_s }
      {"name" => dependency.name, "type" => dependency.type.to_s,
       "requirements" => clauses.sort}
    end.sort_by { |dependency| [dependency["name"], dependency["type"]] }
  end

  def self.identity(spec)
    {"name" => spec.name, "version" => spec.version.to_s,
     "platform" => spec.platform.to_s, "dependencies" => dependencies(spec)}
  end

  def self.observe(root)
    root = Pathname.new(root).realpath.to_s
    fail!("ambiguous Gemfile.lock for pre-lockfile SDK") if File.exist?(File.join(root, "Gemfile.lock"))
    fail!("wrong native RubyGems") unless Gem::VERSION == "1.3.5"
    # Load only freshly regenerated native state. Do not load a codec or the
    # Bundler library before the SDK's selected environment has taken effect.
    environment = File.join(root, "vendor", "gems", "environment.rb")
    within(root, environment)
    # Validate every generated repository path before the SDK environment can
    # evaluate installed gemspecs. A symlink outside the owned root must never
    # become Ruby code executed during observation.
    Find.find(File.join(root, "vendor", "gems")) do |path|
      within(root, path)
      fail!("unsupported special file in native workspace") unless File.file?(path) || File.directory?(path)
    end
    require environment
    specs = Bundler.instance_variable_get(:@bundled_specs)
    fail!("SDK did not expose native selected specifications") unless specs.is_a?(Hash)
    require "bundler"
    fail!("wrong native Bundler interface") unless Bundler::VERSION == "0.8.1"
    Bundler.mode = :local
    manifest = Bundler::Bundle.load(File.join(root, "Gemfile"))
    fail!("unsupported native bundle layout") unless manifest.path.to_s == File.join(root, "vendor", "gems")
    fail!("native RubyGems must remain enabled") unless manifest.environment.rubygems?
    roots = manifest.environment.dependencies.map do |dependency|
      fail!("unsupported native context selection") if dependency.only || dependency.except
      fail!("unsupported native dependency source") if dependency.source
      selected = specs[dependency.name]
      fail!("native root requirement does not match selection") unless selected && dependency.version_requirements.satisfied_by?(selected.version)
      {"name" => dependency.name,
       "requirements" => dependency.version_requirements.requirements.map { |pair| pair[0].to_s + " " + pair[1].to_s }.sort}
    end
    fail!("duplicate native root requirements") unless roots.map { |dependency| dependency["name"] }.uniq.size == roots.size
    names = specs.values.map { |spec| spec.name }
    fail!("duplicate native selected specifications") unless names.uniq.size == names.size
    packages = specs.values.map do |spec|
      fail!("native selection is not a Gem::Specification") unless spec.is_a?(Gem::Specification)
      fail!("native selected name conflicts with SDK key") unless specs[spec.name].equal?(spec)
      installed = within(root, spec.full_gem_path)
      within(root, spec.loaded_from)
      repository = File.dirname(File.dirname(spec.loaded_from))
      archive = File.join(repository, "cache", spec.full_name + ".gem")
      within(root, archive)
      require "rubygems/format"
      cached = Gem::Format.from_file_by_path(archive).spec
      fail!("native archive and selected specification disagree") unless identity(cached) == identity(spec)
      spec.dependencies.each do |dependency|
        next unless dependency.type == :runtime
        selected = specs[dependency.name]
        fail!("native runtime dependency closure is incomplete") unless selected
        fail!("native requirement does not match selected dependency") unless dependency.version_requirements.satisfied_by?(selected.version)
      end
      identity(spec).merge("installedPath" => installed,
        "sourceKind" => "verified-cache",
        "archiveHash" => "sha256-" + [Digest::SHA256.digest(File.open(archive, "rb") { |file| file.read })].pack("m").delete("\n"))
    end
    reachable = []
    pending = roots.map { |dependency| dependency["name"] }
    until pending.empty?
      name = pending.pop
      next if reachable.include?(name)
      reachable << name
      selected = specs[name]
      selected.dependencies.each { |dependency| pending << dependency.name if dependency.type == :runtime }
    end
    fail!("native selected closure contains an unrelated package") unless reachable.sort == names.sort
    {"packages" => packages.sort_by { |package| package["name"] },
     "rootRequirements" => roots.sort_by { |dependency| dependency["name"] }}
  end
end

if __FILE__ == $0
  raise "usage: native_environment_observe.rb WORKSPACE" unless ARGV.size == 1
  observation = PurifierEnvironmentObservation.observe(ARGV[0])
  # The actual environment has selected the codec now. JSON is an SDK/runtime
  # component and its provenance is bound separately by the host SDK identity.
  require "json"
  STDOUT.write(JSON.generate(observation))
  STDOUT.write("\n")
end
