# SPDX-License-Identifier: MIT
# Native Ruby 1.8.4 adapter. Input is bounded primitive TSV, not Ruby/Marshal or
# metadata JSON. Only declared runtime names receive real SDK requirements.
require "rubygems"

module PurifierNativeEnvironmentBindings
  LIMIT = 1048576
  MAX_ENTRIES = 4096

  def self.packages
    @packages || {}
  end

  def self.normalize_dependency(dependency)
    version = packages[dependency.name]
    if version && dependency.type == :runtime
      requirement = Gem::Requirement.new(["= " + version])
      dependency.version_requirements = requirement unless dependency.version_requirements == requirement
    end
    dependency
  end

  def self.load(path)
    raise "bundler-purifier: native binding data exceeds limit" unless File.file?(path) && File.size(path) <= LIMIT
    bytes = File.open(path, "rb") { |file| file.read }
    raise "bundler-purifier: native binding data lacks final newline" unless bytes.empty? || bytes[-1, 1] == "\n"
    records = bytes.empty? ? [] : bytes.split("\n", -1)
    records.pop unless bytes.empty?
    raise "bundler-purifier: too many native bindings" if records.size > MAX_ENTRIES
    parsed = {}
    records.each do |line|
      fields = line.split("\t", -1)
      raise "bundler-purifier: malformed native binding" unless fields.size == 2
      name, version = fields
      raise "bundler-purifier: invalid native binding name" unless name =~ /\A[A-Za-z0-9_.-]+\z/ && name != "." && name != ".." && name.size <= 512
      raise "bundler-purifier: invalid native binding version" unless version =~ /\A[0-9A-Za-z_.-]+\z/ && version.size <= 4096
      raise "bundler-purifier: duplicate native binding" if parsed.has_key?(name)
      # Keep the genuine SDK parser and all of its validity checks.
      Gem::Requirement.new(["= " + version])
      parsed[name] = version.freeze
    end
    operation = ENV["BUNDLER_PURIFIER_NATIVE_OPERATION"] || "runtime"
    raise "bundler-purifier: unsupported native binding operation" unless ["resolve", "observe", "runtime"].include?(operation)
    if @packages
      raise "bundler-purifier: native bindings changed within process" unless @packages == parsed
      raise "bundler-purifier: native binding operation changed within process" unless @operation == operation
      return
    end
    raise "bundler-purifier: unsupported native RubyGems binding interface" unless Gem::VERSION == "1.3.5"
    if operation != "runtime"
      require "bundler"
      raise "bundler-purifier: unsupported native binding interface" unless Bundler::VERSION == "0.8.1" && defined?(Bundler::Dsl)
    end
    raise "bundler-purifier: native specification adapter conflicts with SDK" if Gem::Specification.method_defined?(:purifier_environment_original_dependencies)
    raise "bundler-purifier: native DSL adapter conflicts with SDK" if operation != "runtime" && Bundler::Dsl.method_defined?(:purifier_environment_original_gem)
    Gem::Specification.class_eval do
      alias_method :purifier_environment_original_dependencies, :dependencies
      define_method(:dependencies) do
        dependencies = purifier_environment_original_dependencies
        dependencies.each { |dependency| PurifierNativeEnvironmentBindings.normalize_dependency(dependency) }
        dependencies
      end
    end
    if operation != "runtime"
      Bundler::Dsl.class_eval do
        alias_method :purifier_environment_original_gem, :gem
        define_method(:gem) do |name, *arguments|
          result = purifier_environment_original_gem(name, *arguments)
          PurifierNativeEnvironmentBindings.normalize_dependency(@environment.dependencies.last)
          result
        end
      end
    end
    @packages = parsed.freeze
    @operation = operation
  end
end

if ENV["BUNDLER_PURIFIER_NATIVE_BINDINGS"]
  PurifierNativeEnvironmentBindings.load(ENV["BUNDLER_PURIFIER_NATIVE_BINDINGS"])
end
