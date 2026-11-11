# SPDX-License-Identifier: MIT
# Exercise real SDK factories and serialization after installing the adapter.
require "rubygems"
gem "bundler", "1.17.3"
require "bundler"
require "yaml"
ENV["BUNDLER_PURIFIER_INPUT_DATA"] = Marshal.dump({}).unpack("H*").first
load ARGV.fetch(0)

dependency = Bundler::Dependency.new("ordinary", ">= 1.2")
abort "ordinary dependency changed" unless dependency.class == Bundler::Dependency && dependency.requirement.to_s == ">= 1.2"
abort "copy changed SDK class" unless dependency.dup.class == Bundler::Dependency
child = Class.new(Bundler::Dependency)
abort "subclass factory changed" unless child.new("ordinary", ">= 1.2").class == child

spec = Gem::Specification.new do |value|
  value.name = "control"
  value.version = "1.0"
  value.summary = "control"
  value.authors = ["control"]
  value.add_dependency("ordinary", ">= 1.2")
end
[spec, spec.dup, Gem::Specification.from_yaml(spec.to_yaml), Marshal.load(Marshal.dump(spec))].each do |value|
  abort "serialization changed SDK class" unless value.class == Gem::Specification
  abort "serialization changed dependency" unless value.dependencies.first.requirement.to_s == ">= 1.2"
end
puts "PASS native SDK class, subclass, ordinary requirement, copy, YAML and Marshal"
