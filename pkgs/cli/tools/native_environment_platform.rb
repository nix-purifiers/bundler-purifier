# SPDX-License-Identifier: MIT
# Convert Gem095's installed string coordinate to its genuine builder type.
# No SDK methods or platform coordinates are changed.
require "rubygems"
module PurifierGem095Platform
  def self.for_build(spec)
    raise "bundler-purifier: wrong native platform adapter SDK" unless RUBY_VERSION == "1.8.3" && !defined?(Gem::VERSION) && Gem::RubyGemsVersion == "0.9.5"
    return spec if spec.platform == Gem::Platform::RUBY
    coordinate = spec.platform.to_s
    platform = spec.platform.is_a?(Gem::Platform) ? spec.platform : Gem::Platform.new(coordinate)
    raise "bundler-purifier: native platform conversion changed coordinate or target" unless platform.to_s == coordinate && Gem::Platform.match(platform)
    spec.platform = platform
    spec
  end
end
