# SPDX-License-Identifier: MIT
# Explicit adapter for Gem101's genuine bin directory. This does not change
# Bundler::Repository#valid? or claim native gem-exec equivalence.
require "pathname"
require "find"
require "rubygems/installer"
module PurifierNativeV03Layout
  TOP_LEVEL = %w[cache doc gems environments specifications]

  def self.fail!(message)
    raise "bundler-purifier: " + message
  end

  def self.configuration(root)
    gemfile = File.join(root, "Gemfile")
    fail!("native v03 Gemfile escapes role") unless File.file?(gemfile) && Pathname.new(gemfile).realpath.to_s.index(root + "/") == 0
    file = Bundler::ManifestFile.new(gemfile)
    Bundler::ManifestBuilder.load(file, gemfile)
    repository = File.join(root, "vendor", "gems")
    fail!("unsupported v03 configured paths") unless file.gem_path.to_s == repository && file.bindir.to_s == File.join(root, "bin")
    fail!("v03 RubyGems must remain enabled") unless file.rubygems == true
    fail!("invalid v03 system-gems policy") unless file.system_gems == true || file.system_gems == false
    file.dependencies.each do |dependency|
      fail!("unsupported v03 contexts") if dependency.only || dependency.except
      dependency.to_gem_dependency
    end
    file.sources.each do |source|
      fail!("unsupported v03 source kind") unless source.is_a?(Bundler::Source) && %w[http https file].include?(source.uri.scheme)
    end
    file
  end

  def self.activation(root, archives)
    file = configuration(root)
    repository = File.join(root, "vendor", "gems")
    tree(root)
    index = Gem::SourceIndex.from_gems_in(File.join(repository, "specifications"))
    specs = {}
    index.each do |name, spec|
      fail!("duplicate installed v03 package name") if specs.has_key?(spec.name)
      specs[spec.name] = spec
    end
    selected = Bundler::Resolver.resolve(file.dependencies.map { |dependency| dependency.to_gem_dependency }, index)
    fail!("native v03 activation constraints do not resolve") unless selected
    ids = lambda { |values| values.map { |spec| [spec.name, spec.version.to_s, spec.platform.to_s] }.sort }
    fail!("native v03 activation has unrelated installed packages") unless ids.call(selected) == ids.call(specs.values)
    validate(root, specs, archives)
    file
  end

  def self.tree(root)
    repository = File.join(root, "vendor", "gems")
    fail!("v03 repository escapes role") unless File.directory?(repository) && !File.symlink?(repository) && Pathname.new(repository).realpath.to_s == repository
    entries = Dir.entries(repository) - [".", ".."]
    fail!("unsupported extra v03 repository entry") unless (entries - TOP_LEVEL - ["bin"]).empty?
    entries.each do |name|
      path = File.join(repository, name)
      fail!("v03 repository child is not a directory") unless File.directory?(path) && !File.symlink?(path)
    end
    Find.find(repository) do |path|
      fail!("unsupported v03 repository symlink") if File.symlink?(path)
      fail!("v03 repository path escapes role") unless Pathname.new(path).realpath.to_s == repository || Pathname.new(path).realpath.to_s.index(repository + "/") == 0
      fail!("unsupported v03 repository special file") unless File.file?(path) || File.directory?(path)
    end
    entries
  end

  def self.validate(root, specs, archives)
    repository = File.join(root, "vendor", "gems")
    entries = tree(root)
    # Preserve the SDK's whitelist verbatim when its exceptional bin is absent.
    fail!("native v03 repository whitelist differs") if !entries.include?("bin") && !Bundler::Repository.new(repository).valid?
    bin = Gem.bindir(repository)
    fail!("native v03 bin directory escapes role") unless bin == File.join(repository, "bin")
    expected = {}
    specs.each_value do |spec|
      key = [spec.name, spec.version.to_s, spec.platform.to_s]
      source = archives[key]
      fail!("v03 wrapper lacks verified source archive") unless source
      spec.executables.each do |name|
        fail!("unsafe v03 executable name") unless name =~ /\A[A-Za-z0-9_.-]+\z/ && name != "." && name != ".."
        fail!("conflicting v03 executable owners") if expected.has_key?(name)
        installer = Gem::Installer.new(source[0], :install_dir => repository,
          :bin_dir => File.join(root, "bin"), :ignore_dependencies => true,
          :env_shebang => true, :wrappers => true)
        expected[name] = installer.app_script_text(name)
      end
    end
    if entries.include?("bin")
      fail!("foreign v03 bin directory") if expected.empty?
      fail!("v03 generated wrapper inventory differs") unless (Dir.entries(bin) - [".", ".."]).sort == expected.keys.sort
    else
      fail!("v03 generated wrappers missing") unless expected.empty?
    end
    expected.each do |name, bytes|
      path = File.join(bin, name)
      fail!("v03 wrapper is not a regular owned file") unless File.file?(path) && !File.symlink?(path) && Pathname.new(path).realpath.to_s == path
      fail!("v03 generated wrapper bytes differ from native SDK") unless File.open(path, "rb") { |file| file.read } == bytes
      # Nix canonicalizes executable files to 0555 when committing an output.
      # Mutable arenas must retain the genuine installer's exact 0755 mode.
      stored = root =~ /\A\/nix\/store\/[0-9a-z]{32}-[^\/]+(?:\/|\z)/
      mode = File.stat(path).mode & 07777
      fail!("v03 generated wrapper mode differs from native SDK") unless mode == 0755 || (stored && mode == 0555)
      fail!("v03 wrapper shebang differs from native SDK") unless bytes.split("\n").first == "#!/usr/bin/env ruby"
    end
    expected.keys.sort.map { |name| File.join(bin, name) }
  end
end
