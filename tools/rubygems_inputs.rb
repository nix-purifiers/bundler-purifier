# SPDX-License-Identifier: MIT
# Loaded by a facade Gemfile before Bundler evaluates the user's Gemfile.
require "bundler"
module PurifierGemInputs
  CLASS_METHODS_CAN_MOVE = begin
    probe = Class.new { def purifier_probe; true; end }
    Module.new.send(:define_method, :purifier_probe, probe.instance_method(:purifier_probe))
    true
  rescue TypeError
    false
  end
  INSTANCE_PATCHES = {}
  INSTANCE_FACTORIES = {}
  MODULE_PATCHES = {}

  def self.decorate_instance(object)
    return object if object.frozen?
    object.class.ancestors.reverse_each do |ancestor|
      (INSTANCE_PATCHES[ancestor] || []).each { |patch| object.extend(patch) }
    end
    object
  end

  # Ruby 1.9 rejects transferring class UnboundMethods into modules.
  # Extend genuine SDK instances at allocation/factory/copy boundaries.
  def self.install_instance_patch(target, patch)
    raise TypeError, "this SDK singleton needs a supported method-interception API" if target <= Class
    patches = (INSTANCE_PATCHES[target] ||= [])
    return if patches.include?(patch)
    patches << patch
    unless INSTANCE_FACTORIES[target]
      INSTANCE_FACTORIES[target] = true
      eigenclass = class << target; self; end
      original_allocate = eigenclass.instance_method(:allocate)
      [:new, :allocate, :from_yaml, :_load, :load].each do |factory|
        next unless target.respond_to?(factory)
        original = eigenclass.instance_method(factory)
        if factory == :new && original.owner == Class
          eigenclass.send(:define_method, factory) do |*arguments, &block|
            object = PurifierGemInputs.decorate_instance(original_allocate.bind(self).call)
            object.send(:initialize, *arguments, &block)
            object
          end
        else
          eigenclass.send(:define_method, factory) do |*arguments, &block|
            PurifierGemInputs.decorate_instance(original.bind(self).call(*arguments, &block))
          end
        end
      end
      original_copy = target.instance_method(:initialize_copy)
      target.send(:define_method, :initialize_copy) do |other|
        original_copy.bind(self).call(other)
        PurifierGemInputs.decorate_instance(self)
      end
      target.send(:private, :initialize_copy)
    end
    ObjectSpace.each_object(target) { |object| decorate_instance(object) }
  end
  def self.install_module_patch(target, patch)
    patches = (MODULE_PATCHES[target] ||= [])
    return if patches.include?(patch)
    first = patches.empty?
    patches << patch
    if first
      eigenclass = class << target; self; end
      [:included, :extended].each do |hook|
        original = eigenclass.instance_method(hook)
        eigenclass.send(:define_method, hook) do |receiver|
          result = original.bind(self).call(receiver)
          (PurifierGemInputs::MODULE_PATCHES[self] || []).each do |extension|
            if hook == :included
              PurifierGemInputs.install_patch(receiver, extension)
            else
              receiver.extend(extension) unless receiver.frozen?
            end
          end
          result
        end
        eigenclass.send(:private, hook)
      end
    end
    ObjectSpace.each_object(Class) do |klass|
      install_patch(klass, patch) if klass.ancestors.include?(target)
    end
    ObjectSpace.each_object(target) { |object| object.extend(patch) unless object.frozen? }
  end

  # Before Ruby 2, include cannot override methods defined by a class.
  # Move just the intercepted methods into an included predecessor so the
  # same patches retain their ordinary super chain on the old interpreter.
  def self.install_patch(target, patch)
    return if target.ancestors.include?(patch)
    if target.respond_to?(:prepend)
      target.send(:prepend, patch)
    elsif !CLASS_METHODS_CAN_MOVE
      target.is_a?(Class) ? install_instance_patch(target, patch) : install_module_patch(target, patch)
    else
      # Ruby 1.8 does not propagate later module includes to classes that
      # already included it (Bundler::MatchPlatform is one such module).
      unless target.is_a?(Class)
        consumers = []
        ObjectSpace.each_object(Class) { |klass| consumers << klass if klass.ancestors.include?(target) }
        consumers.each { |klass| install_patch(klass, patch) }
      end
      predecessor = Module.new
      patch.instance_methods(false).each do |name|
        next unless target.method_defined?(name) || target.private_method_defined?(name)
        predecessor.send(:define_method, name, target.instance_method(name))
        own = target.instance_methods(false) + target.private_instance_methods(false)
        target.send(:remove_method, name) if own.map { |method| method.to_s }.include?(name.to_s)
      end
      target.send(:include, predecessor)
      target.send(:include, patch)
    end
  end

  LEGACY_SOURCE_ARRAY = !defined?(Bundler::SourceList)
  LEGACY_YAML_LOCK = !Bundler::Definition.respond_to?(:build)

  if LEGACY_YAML_LOCK
    module SingleRepository
      def remotes
        [uri]
      end
    end
    install_patch(Bundler::Source::Rubygems, SingleRepository)
  end

  def self.rubygems_sources(sources)
    sources.respond_to?(:rubygems_sources) ? sources.rubygems_sources : sources.select { |source| source.is_a?(Bundler::Source::Rubygems) }
  end

  def self.add_rubygems_source(sources, remotes, intrinsic = false)
    return sources.add_rubygems_source("remotes" => remotes) if sources.respond_to?(:add_rubygems_source)
    options = LEGACY_YAML_LOCK ? { "uri" => Array(remotes).first } : { "remotes" => Array(remotes) }
    candidate = Bundler::Source::Rubygems.new(options)
    candidate.extend(IntrinsicSpecs) if intrinsic
    existing = sources.find { |source| source == candidate }
    existing || (sources << candidate; candidate)
  end

  def self.source_requirements(packages, sources)
    result = {}
    packages.each { |name, package| result[name] = source_for(sources, package) }
    result
  end

  # Parse catalogs in the parent process: loading JSON here would activate
  # Ruby's default json gem before Bundler can select a projected json gem.
  PACKAGES = Marshal.load([ENV.fetch("BUNDLER_PURIFIER_INPUT_DATA")].pack("H*"))

  def self.source_for(sources, package)
    return rubygems_sources(sources).find { |source| source.is_a?(IntrinsicSpecs) } if package["intrinsic"]
    repository = package.fetch("repository")
    rubygems_sources(sources).find do |source|
      source.remotes.any? { |remote| remote.to_s == repository }
    end or raise "bundler-purifier: missing Nix repository #{repository}"
  end

  module Requirements
    def requirement
      package = PACKAGES[name]
      package ? Gem::Requirement.new("= #{package.fetch('version')}") : super
    end
  end

  module ProjectDependencies
    def dependencies
      values = super
      return values if name.nil? || name.include?("\0") || values.none? { |dependency| PACKAGES.key?(dependency.name) } || full_gem_path.start_with?(RbConfig::CONFIG.fetch("prefix") + "/")
      mapped = values.map do |dependency|
        PACKAGES.key?(dependency.name) && !dependency.is_a?(Requirements) ? dependency.dup.extend(Requirements) : dependency
      end
      # RubyGems appends declarations through this native collection. A
      # detached array would discard later add_dependency calls.
      values.frozen? ? mapped.freeze : values.replace(mapped)
    end
  end

  module IntrinsicSpecs
    def specs
      @purifier_intrinsic_specs ||= Bundler::Index.build do |index|
        Dir[File.join(Gem.default_dir, "specifications", "{,default/}*.gemspec")].each do |path|
          spec = Gem::Specification.load(path)
          next unless spec && (package = PACKAGES[spec.name]) && package["intrinsic"]
          next unless spec.version.to_s == package.fetch("version")
          spec.source = self
          index << spec
        end
      end
    end

    def installed_specs
      specs
    end

    def cache(*)
      # These files are delivered by the Ruby SDK, not downloaded gems.
    end
  end

  # Bundler 1.x has no local! or local file-source index. Feed the same
  # native archive specifications through its cached source interface.
  module LegacyRepositorySpecs
    def cached_specs
      @purifier_legacy_cached_specs ||= super.tap do |index|
        remotes.each do |remote|
          next unless remote.scheme == "file"
          path = defined?(URI::DEFAULT_PARSER) ? URI::DEFAULT_PARSER.unescape(remote.path) : URI.unescape(remote.path)
          directory = File.join(path, "gems")
          cache_paths = respond_to?(:caches) ? caches : instance_variable_get(:@caches)
          cache_paths << Pathname.new(directory) unless cache_paths.include?(Pathname.new(directory))
          Dir[File.join(directory, "*.gem")].sort.each do |archive|
            spec = Bundler.rubygems.spec_from_gem(archive)
            next unless PACKAGES.key?(spec.name)
            spec.source = self
            index << spec
          end
        end
      end
    end
  end

  module Runtime
    def setup(*arguments)
      result = super
      PurifierGemInputs.install_patch(Gem::Dependency, Requirements)
      result
    end
  end

  module YamlRepositorySpecs
    def fetch(spec)
      return super if spec.respond_to?(:fetch_platform)
      # These specifications came from the actual local gem archive, so
      # their platform is already materialized rather than remotely lazy.
      Gem::RemoteFetcher.fetcher.download(spec, uri, Gem.dir)
    end

    def specs
      @purifier_yaml_specs ||= Bundler::Index.build do |index|
        remotes.each do |remote|
          next unless remote.scheme == "file"
          path = URI.unescape(remote.path)
          Dir[File.join(path, "gems", "*.gem")].sort.each do |archive|
            spec = Gem::Format.from_file_by_path(archive).spec
            next unless PACKAGES.key?(spec.name)
            installed = Gem::Specification.find_all_by_name(spec.name, "= #{spec.version}").find do |candidate|
              candidate.platform.to_s == spec.platform.to_s && candidate.loaded_from &&
                candidate.full_gem_path.start_with?(Gem.dir + "/") && File.file?(candidate.loaded_from)
            end
            spec = installed if installed
            spec.source = self
            index << spec
          end
        end
      end
    end
  end

  # Native Bundler checksum locks need the checksums of the actual local
  # archives before frozen resolution, just as an ordinary source supplies.
  def self.register_repository_checksums(source)
    return unless defined?(Bundler::Checksum) && Bundler::Checksum.respond_to?(:from_gem) && source.respond_to?(:checksum_store)
    return if Bundler.settings[:disable_checksum_validation]
    source.remotes.each do |remote|
      next unless remote.scheme == "file"
      path = remote.parser.unescape(remote.path)
      Dir[File.join(path, "gems", "*.gem")].sort.each do |archive|
        spec = Bundler.rubygems.spec_from_gem(archive)
        next unless PACKAGES.key?(spec.name)
        File.open(archive, "rb") do |input|
          source.checksum_store.register(spec, Bundler::Checksum.from_gem(input, archive))
        end
      end
    end
  end

  module Dsl
    def to_definition(*arguments)
      intrinsics = PACKAGES.values.select { |package| package["intrinsic"] }
      intrinsics.each do |package|
        unless package.fetch("sdk") == RbConfig::CONFIG.fetch("prefix")
          raise "bundler-purifier: Nix input requires Ruby SDK #{package.fetch('sdk')}, current SDK is #{RbConfig::CONFIG.fetch('prefix')}"
        end
      end
      if intrinsics.any?
        source = PurifierGemInputs.add_rubygems_source(@sources, [], true)
        source.extend(IntrinsicSpecs)
        source.local! if source.respond_to?(:local!)
      end
      PACKAGES.values.reject { |package| package["intrinsic"] }.map { |package| package.fetch("repository") }.uniq.each do |repository|
        source = PurifierGemInputs.add_rubygems_source(@sources, repository)
        if source.respond_to?(:local!)
          source.local!
        else
          source.extend(LEGACY_YAML_LOCK ? YamlRepositorySpecs : LegacyRepositorySpecs)
        end
        source.cached! if source.respond_to?(:cached!) && ENV["BUNDLER_PURIFIER_RUNTIME"] != "1"
        PurifierGemInputs.register_repository_checksums(source)
      end
      lockfile, unlock = arguments
      if unlock != true && lockfile && File.file?(lockfile)
        changed = Bundler::LockfileParser.new(File.read(lockfile)).specs.map do |spec|
          package = PACKAGES[spec.name]
          next unless package
          source = spec.source
          same_source = source.is_a?(Bundler::Source::Rubygems) &&
            (package["intrinsic"] ? source.remotes.empty? : source.remotes.any? { |remote| remote.to_s.sub(/\/$/, "") == package.fetch("repository").sub(/\/$/, "") })
          spec.name unless spec.version.to_s == package.fetch("version") && same_source
        end
        changed.compact!
        unlock = (unlock || {}).dup
        unlock[:gems] = (Array(unlock[:gems]) + changed).uniq
        arguments[1] = unlock
      end
      definition = super(*arguments)
      unless defined?(Bundler::SourceMap)
        PurifierGemInputs.rubygems_sources(definition.send(:sources)).each do |source|
          next unless source.remotes.any? { |remote| remote.scheme == "file" }
          next if LEGACY_YAML_LOCK && !source.purifier_nix_repository?
          source.extend(LEGACY_YAML_LOCK ? YamlRepositorySpecs : LegacyRepositorySpecs)
          source.cached! if source.respond_to?(:cached!) && ENV["BUNDLER_PURIFIER_RUNTIME"] != "1"
        end
      end
      if intrinsics.any?
        PurifierGemInputs.rubygems_sources(definition.send(:sources)).select { |source| source.remotes.empty? }.each do |source|
          source.extend(IntrinsicSpecs)
          source.local! if source.respond_to?(:local!)
        end
      end
      definition
    end

    def gem(name, *arguments)
      if (package = PACKAGES[name]) && !package["intrinsic"]
        options = arguments.last.is_a?(Hash) ? arguments.pop.dup : {}
        options.delete_if do |key, _|
          %w[source git path github gitlab gist branch ref tag glob submodules].include?(key.to_s)
        end
        if PurifierGemInputs::LEGACY_SOURCE_ARRAY
          repository_source = PurifierGemInputs.add_rubygems_source(@sources, package.fetch("repository"))
          result = source(repository_source) { super(name, *(arguments + [options])) }
          if PurifierGemInputs::LEGACY_YAML_LOCK
            seen = false
            @sources.delete_if do |candidate|
              next false unless candidate.equal?(repository_source)
              duplicate = seen
              seen = true
              duplicate
            end
          end
          return result
        end
        options[:source] = package.fetch("repository")
        arguments << options
      end
      super(name, *arguments)
    end
  end

  module SourceMap
    def direct_requirements
      super.merge(PurifierGemInputs.source_requirements(PACKAGES, sources))
    end

    def all_requirements
      super.merge(PurifierGemInputs.source_requirements(PACKAGES, sources))
    end
  end
end
if PurifierGemInputs::LEGACY_SOURCE_ARRAY
  module PurifierGemInputs::RepositoryIdentity
    def purifier_repository_identity
      [is_a?(PurifierGemInputs::IntrinsicSpecs), remotes.map { |remote| remote.to_s.sub(/\/$/, "") }]
    end

    def purifier_nix_repository?
      return true if is_a?(PurifierGemInputs::IntrinsicSpecs)
      remotes.any? do |remote|
        PurifierGemInputs::PACKAGES.values.any? do |package|
          !package["intrinsic"] && remote.to_s.sub(/\/$/, "") == package.fetch("repository").sub(/\/$/, "")
        end
      end
    end

    def hash
      purifier_nix_repository? ? purifier_repository_identity.hash : super
    end

    def eql?(other)
      return super unless purifier_nix_repository? || (other.is_a?(Bundler::Source::Rubygems) && other.purifier_nix_repository?)
      other.is_a?(Bundler::Source::Rubygems) && purifier_repository_identity == other.purifier_repository_identity
    end

    def ==(other)
      eql?(other)
    end
  end
  PurifierGemInputs.install_patch(Bundler::Source::Rubygems, PurifierGemInputs::RepositoryIdentity)
end
PurifierGemInputs.install_patch(Bundler::Dependency, PurifierGemInputs::Requirements)
PurifierGemInputs.install_patch(Gem::Specification, PurifierGemInputs::ProjectDependencies)
PurifierGemInputs.install_patch(Bundler::Runtime, PurifierGemInputs::Runtime)
PurifierGemInputs.install_patch(Bundler::Dsl, PurifierGemInputs::Dsl)
unless Bundler::Dsl.method_defined?(:eval_gemfile)
  module PurifierGemInputs::LegacyGemfileEvaluation
    def eval_gemfile(path)
      text = Bundler.respond_to?(:read_file) ? Bundler.read_file(path.to_s) : File.read(path.to_s)
      instance_eval(text, path.to_s, 1)
    end
  end
  PurifierGemInputs.install_patch(Bundler::Dsl, PurifierGemInputs::LegacyGemfileEvaluation)
end

if defined?(Bundler::SourceMap)
  PurifierGemInputs.install_patch(Bundler::SourceMap, PurifierGemInputs::SourceMap)
else
  # Bundler 1.x passes the equivalent mapping directly from Definition.
  module PurifierGemInputs::LegacySourceRequirements
    def source_requirements
      requirements = super
      provided = PurifierGemInputs.source_requirements(PurifierGemInputs::PACKAGES, sources)
      # Earlier resolvers consume native indexes; later ones announce a
      # :default source and consume source objects instead.
      unless requirements.key?(:default)
        indexes = {}
        provided.each { |name, source| indexes[name] = source.specs }
        provided = indexes
      end
      requirements.merge(provided)
    end
  end
  PurifierGemInputs.install_patch(Bundler::Definition, PurifierGemInputs::LegacySourceRequirements)
end

# Native add/remove must edit the user's Gemfile, rather than the lent facade.
# SDKs predating Injector keep their native command surface unchanged.
if defined?(Bundler::Injector)
require "bundler/injector"
module PurifierGemInputs::Injector
  def append_to(path, lines)
    original = ENV["BUNDLER_PURIFIER_ORIGINAL_GEMFILE"]
    path = Pathname.new(original) if original && path.to_s == Bundler.default_gemfile.to_s
    super(path, lines)
  end

  def remove_deps(path)
    original = ENV["BUNDLER_PURIFIER_ORIGINAL_GEMFILE"]
    return [] if original && path.to_s == Bundler.default_gemfile.to_s && path.to_s != original
    super
  end
end
PurifierGemInputs.install_patch(Bundler::Injector, PurifierGemInputs::Injector)
end

# Other lock platforms describe ordinary downloads. A declared Nix input
# supplies its artifact for the current target; never require foreign builds
# of that input just to retain those ordinary platform entries.
module PurifierGemInputs::Platforms
  def match_platform(platform)
    package = PurifierGemInputs::PACKAGES[name]
    if package && version.to_s == package.fetch("version")
      super(Gem::Platform.local)
    else
      super
    end
  end
end
unless PurifierGemInputs::LEGACY_YAML_LOCK
  require "bundler/match_platform" unless defined?(Bundler::MatchPlatform)
  PurifierGemInputs.install_patch(Bundler::MatchPlatform, PurifierGemInputs::Platforms)
end

require "bundler/resolver"
require "bundler/resolver/spec_group" unless defined?(Bundler::Resolver::SpecGroup) || PurifierGemInputs::LEGACY_YAML_LOCK
module PurifierGemInputs::ResolverDependencies
  def dependencies
    super.map do |dependency|
      PurifierGemInputs::PACKAGES.key?(dependency.name) ? dependency.dup.extend(PurifierGemInputs::Requirements) : dependency
    end
  end
end
PurifierGemInputs.install_patch(Bundler::Resolver::SpecGroup, PurifierGemInputs::ResolverDependencies) if defined?(Bundler::Resolver::SpecGroup)

# The earliest Definition builds source requirements inside resolve instead
# of exposing a source_requirements method. Keep its sources scoped to this
# native resolution, then pass the same indexes to its native resolver.
if PurifierGemInputs::LEGACY_SOURCE_ARRAY
  # These SDKs merge the first RubyGems source as their ordinary source.
  # Keep ordinary RubyGems sources ahead of explicit Nix sources in just
  # the RubyGems slots; other sources and ordinary remote order are retained.
  module PurifierGemInputs::LegacySourceConvergence
    def converge_sources
      if @sources.any? { |source| source.is_a?(Bundler::Source::Rubygems) && source.purifier_nix_repository? }
        [@sources, @locked_sources].each do |sources|
          rubygems = sources.select { |source| source.is_a?(Bundler::Source::Rubygems) }
          ordinary, provided = rubygems.partition { |source| !source.purifier_nix_repository? }
          ordered = ordinary + provided
          sources.replace(sources.map { |source| source.is_a?(Bundler::Source::Rubygems) ? ordered.shift : source })
        end
      end
      super
    end
  end
  unless PurifierGemInputs::LEGACY_YAML_LOCK
    PurifierGemInputs.install_patch(Bundler::Definition, PurifierGemInputs::LegacySourceConvergence)
    Bundler::Definition.send(:private, :converge_sources)
  end
  module PurifierGemInputs::InlineDefinitionSources
    def resolve(*arguments)
      previous = Thread.current[:purifier_definition_sources]
      Thread.current[:purifier_definition_sources] = sources
      super(*arguments)
    ensure
      Thread.current[:purifier_definition_sources] = previous
    end
  end
  module PurifierGemInputs::InlineResolverSources
    def resolve(*arguments)
      sources = Thread.current[:purifier_definition_sources]
      if sources
        source_requirements = (arguments[2] || {}).dup
        PurifierGemInputs.source_requirements(PurifierGemInputs::PACKAGES, sources).each do |name, source|
          source_requirements[name] = source.specs
        end
        arguments[2] = source_requirements
      end
      super(*arguments)
    end
  end
  target = PurifierGemInputs::LEGACY_YAML_LOCK ? Bundler::Environment : Bundler::Definition
  PurifierGemInputs.install_patch(target, PurifierGemInputs::InlineDefinitionSources)
  target.send(:private, :resolve) if PurifierGemInputs::LEGACY_YAML_LOCK
  PurifierGemInputs.install_patch(class << Bundler::Resolver; self; end, PurifierGemInputs::InlineResolverSources)
end

if PurifierGemInputs::LEGACY_YAML_LOCK
  def PurifierGemInputs.yaml_sources(values)
    values.each do |source|
      if source.is_a?(Bundler::Source::Rubygems) && source.purifier_nix_repository?
        source.extend(PurifierGemInputs::YamlRepositorySpecs)
      end
    end
    values
  end
  module PurifierGemInputs::YamlDefinitionSources
    def sources
      PurifierGemInputs.yaml_sources(super)
    end
  end
  module PurifierGemInputs::YamlLockedSources
    def sources
      PurifierGemInputs.yaml_sources(super)
    end
  end
  PurifierGemInputs.install_patch(Bundler::Definition, PurifierGemInputs::YamlDefinitionSources)
  PurifierGemInputs.install_patch(Bundler::Definition::Locked, PurifierGemInputs::YamlLockedSources)
  # The old installer eagerly fetches every ordinary repository before
  # resolving, even when each requirement has an explicit Nix source.
  # Retain its original index and ordering, loading it only when its native
  # resolver actually asks for a package outside those explicit sources.
  class PurifierGemInputs::DeferredIndex
    def initialize(&loader)
      @loader = loader
    end

    def search(dependency)
      (@index ||= @loader.call).search(dependency)
    end

    def sources
      (@index ||= @loader.call).sources
    end
  end

  module PurifierGemInputs::DeferredOrdinaryIndex
    def remote_index
      @purifier_deferred_index ||= PurifierGemInputs::DeferredIndex.new { super }
    end
  end
  require "bundler/installer"
  PurifierGemInputs.install_patch(Bundler::Installer, PurifierGemInputs::DeferredOrdinaryIndex)
  Bundler::Installer.send(:private, :remote_index)
end
