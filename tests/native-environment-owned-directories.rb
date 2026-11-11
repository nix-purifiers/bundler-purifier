# SPDX-License-Identifier: MIT
require "tmpdir"
require "fileutils"
require "digest"
require_relative "../tools/native_environment_frontend"

Dir.mktmpdir("native-owned-directory-") do |arena|
  root = File.join(arena, "project")
  outside = File.join(arena, "outside")
  FileUtils.mkdir_p([root, outside])
  sentinel = File.join(outside, "sentinel")
  File.binwrite(sentinel, "preserve exact bytes\n")
  original_mode = File.stat(sentinel).mode
  context = Struct.new(:root, :lockfile_path).new(root, File.join(root, "lock.json"))
  frontend = PurifierNativeEnvironmentFrontend.new(context)
  %w[vendor .bundler-purifier].each do |role|
    File.symlink(outside, File.join(root, role))
    begin
      frontend.owned_directory(File.join(root, role, "missing", "nested"), mode: 0700)
      raise "accepted outside #{role} ancestor"
    rescue PurifierNativeEnvironment::Invalid
      raise "created outside directories" unless Dir.children(outside) == ["sentinel"]
      raise "changed outside sentinel" unless File.binread(sentinel) == "preserve exact bytes\n" && File.stat(sentinel).mode == original_mode
    ensure
      File.unlink(File.join(root, role))
    end
  end
  source = File.join(arena, "source.gem")
  File.binwrite(source, "archive fixture bytes")
  File.symlink(outside, File.join(root, "vendor"))
  begin
    frontend.vendor(source, "vendor/cache/example.gem", PurifierNativeEnvironment.hash_file(source))
    raise "vendor followed outside symlink"
  rescue PurifierNativeEnvironment::Invalid
    raise "vendor created outside cache" unless Dir.children(outside) == ["sentinel"]
  ensure
    File.unlink(File.join(root, "vendor"))
  end
  frontend.owned_directory(File.join(root, "vendor", "cache"), mode: 0755)
  raise "owned directory was not created" unless File.directory?(File.join(root, "vendor", "cache"))
end
puts "4 native owned-directory controls passed"
