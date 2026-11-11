# SPDX-License-Identifier: MIT
# Independent SDK identity process. No project manifest or captured state is
# evaluated here. This uses only genuine native component versions and APIs.
require "rubygems"
require "pathname"
require "digest/sha2"
gem "bundler", "= 0.8.1"
require "bundler"
gem "json", "= 1.8.6"
require "json"
raise "native SDK requires C JSON" unless JSON.parser == JSON::Ext::Parser

config = defined?(RbConfig) ? RbConfig::CONFIG : Config::CONFIG
gem_library = $LOAD_PATH.map { |path| File.join(path, "rubygems.rb") }.detect { |path| File.file?(path) }
raise "native RubyGems library not found" unless gem_library
real = lambda { |path| Pathname.new(path).realpath.to_s }
executable = real.call("/proc/self/exe")
components = [
  {"name" => "ruby", "version" => RUBY_VERSION, "library" => real.call(config["prefix"])},
  {"name" => "rubygems", "version" => Gem::VERSION, "library" => real.call(File.dirname(File.dirname(gem_library)))}
]
["bundler", "json"].each do |name|
  spec = Gem.loaded_specs[name]
  raise "native component was not activated" unless spec.is_a?(Gem::Specification)
  components << {"name" => name, "version" => spec.version.to_s, "library" => real.call(spec.full_gem_path)}
end
json_root = components.detect { |component| component["name"] == "json" }["library"]
parser_paths = File.readlines("/proc/self/maps").map { |line| line.split.last }.uniq.select { |path| path && path =~ /json\/ext\/parser.so$/ }
raise "native SDK C JSON origin differs from activated component" unless !parser_paths.empty? && parser_paths.all? { |path| real.call(path).index(json_root + "/") == 0 }
puts JSON.generate({
  "ruby" => RUBY_VERSION,
  "patchlevel" => defined?(RUBY_PATCHLEVEL) ? RUBY_PATCHLEVEL : nil,
  "abi" => config["ruby_version"],
  "platform" => Gem::Platform.local.to_s,
  "executable" => executable,
  "interpreter" => "sha256-" + [Digest::SHA256.digest(File.open(executable, "rb") { |file| file.read })].pack("m").delete("\n"),
  "components" => components,
  "clientReport" => {"name" => "Bundler::VERSION", "value" => Bundler::VERSION},
  "rubygemsReport" => {"name" => "Gem::VERSION", "value" => Gem::VERSION}
})
