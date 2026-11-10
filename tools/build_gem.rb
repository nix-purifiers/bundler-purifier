# SPDX-License-Identifier: MIT
# Native RubyGems builds the archive; old codecs have no gem build --output.
require "fileutils"
require "rubygems/package"

specification = Gem::Specification.load(ARGV.fetch(0))
raise "could not load gem specification #{ARGV.fetch(0)}" unless specification
archive = if Gem::Package.respond_to?(:build)
  Gem::Package.build(specification)
else
  require "rubygems/builder"
  Gem::Builder.new(specification).build
end
destination = ARGV.fetch(1)
FileUtils.mv(archive, destination) unless File.expand_path(archive) == File.expand_path(destination)
