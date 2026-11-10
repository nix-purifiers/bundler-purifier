# SPDX-License-Identifier: MIT
# Add a genuine SDK update to the private publication registry. Keep all
# projected gem specifications byte-identical to the produced repository.
require "rubygems"
require "rubygems/package"
require "rubygems/format" unless Gem::Package.respond_to?(:new)
require "zlib"
require "fileutils"

root, archive, repository = ARGV
spec = if Gem::Package.respond_to?(:new)
  Gem::Package.new(archive).spec
else
  Gem::Format.from_file_by_path(archive).spec
end
raise "wrong SDK fixture" unless spec.name == "rubygems-update" && spec.version.to_s == Gem::VERSION
FileUtils.mkdir_p(File.join(root, "quick", "Marshal.4.8"))
path = File.join(root, "quick", "Marshal.4.8", "#{spec.original_name}.gemspec.rz")
File.open(path, "wb") { |file| file.write(Zlib::Deflate.deflate(Marshal.dump(spec))) }
all = []
["specs", "latest_specs", "prerelease_specs"].each do |name|
  original = File.join(repository, "#{name}.4.8.gz")
  # The actual consumer must understand the produced index's native Marshal.
  values = Zlib::GzipReader.open(original) { |reader| Marshal.load(reader.read) }
  all.concat(values)
  if name == "prerelease_specs"
    FileUtils.cp(original, File.join(root, "#{name}.4.8.gz"))
  else
    values = (values + [[spec.name, spec.version, spec.platform.to_s]]).sort
    data = Marshal.dump(values)
    File.open(File.join(root, "#{name}.4.8"), "wb") { |file| file.write(data) }
    Zlib::GzipWriter.open(File.join(root, "#{name}.4.8.gz")) { |file| file.write(data) }
  end
end
puts "NATIVE_INDEX|#{RUBY_VERSION}|#{Gem::VERSION}|#{all.uniq.size + 1}"
