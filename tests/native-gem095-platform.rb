# SPDX-License-Identifier: MIT
require "rubygems"
require "rubygems/format"
require "fileutils"
require File.expand_path("../pkgs/cli/tools/native_environment_platform", File.dirname(__FILE__))
root = ARGV.fetch(0)
FileUtils.mkdir_p(root)
spec = Gem.loaded_specs.fetch("json").dup
raise "missing actual compiled target" unless spec.platform.to_s == Gem::Platform.local.to_s
before = spec.platform.to_s
File.open(File.join(root, "before.yaml"), "wb") { |f| f.write(spec.to_yaml) }
File.open(File.join(root, "before.gemspec"), "wb") { |f| f.write(spec.to_ruby) }
begin
  spec.validate
  raise "original loaded platform unexpectedly builds"
rescue Gem::InvalidSpecificationException => error
  raise unless error.message.index("invalid platform")
  File.open(File.join(root, "original-validation-error"), "wb") { |f| f.write(error.message) }
end
PurifierGem095Platform.for_build(spec)
raise "coordinate changed" unless spec.platform.to_s == before
raise "CPU/OS/version changed" unless spec.platform.to_a == Gem::Platform.local.to_a
spec.validate
File.open(File.join(root, "after.yaml"), "wb") { |f| f.write(spec.to_yaml) }
File.open(File.join(root, "after.gemspec"), "wb") { |f| f.write(spec.to_ruby) }
["aarch64-linux", "malformed", "../x86_64-linux"].each do |coordinate|
  candidate = spec.dup
  candidate.platform = coordinate
  begin
    PurifierGem095Platform.for_build(candidate)
  rescue RuntimeError => error
    raise unless error.message.index("coordinate or target")
    puts "REJECT|" + coordinate
    next
  end
  raise "accepted wrong or malformed native platform"
end
puts "PLATFORM|" + before + "|" + spec.platform.to_a.inspect
