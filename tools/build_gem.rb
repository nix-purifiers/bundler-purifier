# SPDX-License-Identifier: MIT
# Native RubyGems builds the archive; old codecs have no gem build --output.
require "fileutils"
require "rubygems/package"

specification = Gem::Specification.load(ARGV.fetch(0))
raise "could not load gem specification #{ARGV.fetch(0)}" unless specification
archive = Gem::Package.build(specification)
destination = ARGV.fetch(1)
FileUtils.mv(archive, destination) unless File.expand_path(archive) == File.expand_path(destination)
