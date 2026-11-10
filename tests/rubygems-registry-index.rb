# SPDX-License-Identifier: MIT
# Native index for the private RubyGems 1.8 publication fixture.
require "rubygems"
require "rubygems/package"
require "rubygems/format" unless Gem::Package.respond_to?(:new)
require "zlib"
require "fileutils"

root = ARGV.shift
tuples = []
FileUtils.mkdir_p(File.join(root, "quick", "Marshal.4.8"))
ARGV.each do |archive|
  spec = if Gem::Package.respond_to?(:new)
    Gem::Package.new(archive).spec
  else
    Gem::Format.from_file_by_path(archive).spec
  end
  tuples << [spec.name, spec.version, spec.platform.to_s]
  path = File.join(root, "quick", "Marshal.4.8", "#{spec.original_name}.gemspec.rz")
  File.open(path, "wb") { |file| file.write(Zlib::Deflate.deflate(Marshal.dump(spec))) }
end
# This fixture has exactly one version of each package.
raise "duplicate fixture package" unless tuples.map { |tuple| tuple.first }.uniq.size == tuples.size
tuples = tuples.sort
stable = tuples.reject { |tuple| tuple[1].prerelease? }
prerelease = tuples.select { |tuple| tuple[1].prerelease? }
{ "specs" => stable, "latest_specs" => stable, "prerelease_specs" => prerelease }.each do |name, values|
  data = Marshal.dump(values)
  File.open(File.join(root, "#{name}.4.8"), "wb") { |file| file.write(data) }
  Zlib::GzipWriter.open(File.join(root, "#{name}.4.8.gz")) { |file| file.write(data) }
end
puts "NATIVE_INDEX|#{RUBY_VERSION}|#{Gem::VERSION}|#{tuples.size}"
