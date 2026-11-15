# SPDX-License-Identifier: MIT
# Observe root project gemspecs separately from the native dependency closure.
require "rubygems"
require "pathname"

project = Pathname.new(ARGV.shift).realpath.to_s
environment = ARGV.shift
raise "bundler-purifier: native environment is missing" unless environment && File.file?(environment)
require File.expand_path(environment)
rows = ARGV.map do |relative|
  path = Pathname.new(File.join(project, relative)).realpath.to_s
  raise "bundler-purifier: project gemspec escapes project role" unless path.index(project + "/") == 0 && File.file?(path)
  require "rubygems/source_index" unless Gem::Specification.respond_to?(:load)
  spec = Dir.chdir(File.dirname(path)) { Gem::Specification.respond_to?(:load) ? Gem::Specification.load(path) : Gem::SourceIndex.load_specification(path) }
  raise "bundler-purifier: project gemspec did not return a native specification" unless spec.is_a?(Gem::Specification)
  Dir.chdir(File.dirname(path)) { spec.validate }
  raise "bundler-purifier: native Gem095 executables require bin payloads" if !defined?(Gem::VERSION) && Gem::RubyGemsVersion == "0.9.5" && !spec.executables.empty? && spec.bindir != "bin"
  {"path" => relative, "name" => spec.name, "version" => spec.version.to_s,
   "platform" => spec.platform.to_s, "fullName" => spec.full_name,
   "executables" => spec.executables, "bindir" => spec.bindir,
   "requirePaths" => spec.require_paths,
   "dependencies" => spec.dependencies.map do |dependency|
     {"name" => dependency.name, "type" => ((!defined?(Gem::VERSION) && ["1.0.1", "0.9.5"].include?(Gem::RubyGemsVersion)) ? "runtime" : dependency.type.to_s),
      "requirements" => ((!defined?(Gem::VERSION) && ["1.0.1", "0.9.5"].include?(Gem::RubyGemsVersion)) ? dependency.version_requirements.as_list.sort : dependency.version_requirements.requirements.map { |pair| pair[0].to_s + " " + pair[1].to_s }.sort)}
   end.sort_by { |dependency| [dependency["name"], dependency["type"]] }}
end
names = rows.map { |row| row["name"] }
raise "bundler-purifier: duplicate root project specification" unless names.uniq.size == names.size
require "json"
puts JSON.generate(rows.sort_by { |row| row["name"] })
