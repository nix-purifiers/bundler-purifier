# SPDX-License-Identifier: MIT
# Loaded by a facade Gemfile before Bundler evaluates the user's Gemfile.
require "bundler"
module PurifierGemInputs
  # Before Ruby 2, include cannot override methods defined by a class.
  # Move just the intercepted methods into an included predecessor so the
  # same patches retain their ordinary super chain on the old interpreter.
  def self.install_patch(target, patch)
    return if target.ancestors.include?(patch)
    if target.respond_to?(:prepend)
      target.send(:prepend, patch)
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

  def self.source_requirements(packages, sources)
    result = {}
    packages.each { |name, package| result[name] = source_for(sources, package) }
    result
  end

  # Parse catalogs in the parent process: loading JSON here would activate
  # Ruby's default json gem before Bundler can select a projected json gem.
  PACKAGES = Marshal.load([ENV.fetch("BUNDLER_PURIFIER_INPUT_DATA")].pack("H*"))

  def self.source_for(sources, package)
    return sources.rubygems_sources.find { |source| source.is_a?(IntrinsicSpecs) } if package["intrinsic"]
    repository = package.fetch("repository")
    sources.rubygems_sources.find do |source|
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
      values.map { |dependency| PACKAGES.key?(dependency.name) ? dependency.dup.extend(Requirements) : dependency }
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
          caches << Pathname.new(directory) unless caches.include?(Pathname.new(directory))
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

  module Dsl
    def to_definition(*arguments)
      intrinsics = PACKAGES.values.select { |package| package["intrinsic"] }
      intrinsics.each do |package|
        unless package.fetch("sdk") == RbConfig::CONFIG.fetch("prefix")
          raise "bundler-purifier: Nix input requires Ruby SDK #{package.fetch('sdk')}, current SDK is #{RbConfig::CONFIG.fetch('prefix')}"
        end
      end
      if intrinsics.any?
        source = @sources.add_rubygems_source("remotes" => [])
        source.extend(IntrinsicSpecs)
        source.local! if source.respond_to?(:local!)
      end
      PACKAGES.values.reject { |package| package["intrinsic"] }.map { |package| package.fetch("repository") }.uniq.each do |repository|
        source = @sources.add_rubygems_source("remotes" => repository)
        if source.respond_to?(:local!)
          source.local!
        else
          source.extend(LegacyRepositorySpecs)
        end
        source.cached! unless ENV["BUNDLER_PURIFIER_RUNTIME"] == "1"
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
        definition.send(:sources).rubygems_sources.each do |source|
          next unless source.remotes.any? { |remote| remote.scheme == "file" }
          source.extend(LegacyRepositorySpecs)
          source.cached! unless ENV["BUNDLER_PURIFIER_RUNTIME"] == "1"
        end
      end
      if intrinsics.any?
        definition.send(:sources).rubygems_sources.select { |source| source.remotes.empty? }.each do |source|
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
PurifierGemInputs.install_patch(Bundler::Dependency, PurifierGemInputs::Requirements)
PurifierGemInputs.install_patch(Gem::Specification, PurifierGemInputs::ProjectDependencies)
PurifierGemInputs.install_patch(Bundler::Runtime, PurifierGemInputs::Runtime)
PurifierGemInputs.install_patch(Bundler::Dsl, PurifierGemInputs::Dsl)
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
require "bundler/match_platform"
PurifierGemInputs.install_patch(Bundler::MatchPlatform, PurifierGemInputs::Platforms)

require "bundler/resolver"
require "bundler/resolver/spec_group" unless defined?(Bundler::Resolver::SpecGroup)
module PurifierGemInputs::ResolverDependencies
  def dependencies
    super.map do |dependency|
      PurifierGemInputs::PACKAGES.key?(dependency.name) ? dependency.dup.extend(PurifierGemInputs::Requirements) : dependency
    end
  end
end
PurifierGemInputs.install_patch(Bundler::Resolver::SpecGroup, PurifierGemInputs::ResolverDependencies)
