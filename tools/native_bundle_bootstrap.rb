# SPDX-License-Identifier: MIT
# Activate the selected consumer SDK before loading its own executable.
require "rubygems"
require "rubygems/user_interaction" unless defined?(Gem::SilentUI)
gem "bundler", ENV.fetch("BUNDLER_PURIFIER_BUNDLER_VERSION", ">= 0")
require "bundler"
require "bundler/cli"
require "bundler/definition"
require File.expand_path("native_index", File.dirname(__FILE__))

# Early Path::Installer stores @spec directly, while newer RubyGems'
# inherited accessor expects @package. Later Bundler supplies this reader.
unless defined?(Bundler::SourceList)
  require "bundler/source"
  if defined?(Bundler::Source::Path::Installer) && !Bundler::Source::Path::Installer.instance_methods(false).map { |name| name.to_s }.include?("spec")
    class Bundler::Source::Path::Installer
      attr_reader :spec
    end
  end
end
# Early Bundler hard-codes vendor/cache. Honor the isolated cache setting
# through the later native convention; native app-config support is retained.
if Bundler.respond_to?(:app_cache) && !Bundler::Settings.method_defined?(:app_cache_path)
  require "bundler/runtime"
  class Bundler::Runtime
    def cache_path
      Bundler.app_cache
    end
    private :cache_path
  end
  class << Bundler
    alias_method :purifier_original_app_cache, :app_cache
    def app_cache
      cache = ENV["BUNDLE_CACHE_PATH"] || settings[:cache_path]
      cache ? root.join(cache) : purifier_original_app_cache
    end
  end
end
if !Bundler.respond_to?(:app_cache) && Bundler.respond_to?(:cache)
  class Bundler::Settings
    alias_method :purifier_original_config_file, :config_file
    def config_file
      directory = ENV["BUNDLE_APP_CONFIG"]
      directory ? Pathname.new(directory).join("config") : purifier_original_config_file
    end
    private :config_file
  end
  require "bundler/runtime"
  if Bundler::Runtime.method_defined?(:cache_path) || Bundler::Runtime.private_method_defined?(:cache_path)
    class Bundler::Runtime
      alias_method :purifier_original_cache_path, :cache_path
      def cache_path
        directory = ENV["BUNDLE_CACHE_PATH"] || Bundler.settings[:cache_path]
        directory ? Pathname.new(directory) : purifier_original_cache_path
      end
      private :cache_path
    end
  end
  # This RGProxy predates SilentUI's stream initialization. Keep its own
  # forwarding behavior and initialize the real native superclass state.
  class Bundler::UI::RGProxy
    alias_method :purifier_original_initialize, :initialize
    def initialize(ui)
      super()
      purifier_original_initialize(ui)
    end
  end
  class << Bundler
    alias_method :purifier_original_cache, :cache
    def cache
      path = ENV["BUNDLE_CACHE_PATH"] || Bundler.settings[:cache_path]
      path ? Pathname.new(path) : purifier_original_cache
    end
  end
  if Bundler::Index.respond_to?(:application_cached_gems)
    class << Bundler::Index
      alias_method :purifier_original_application_cached_gems, :application_cached_gems
      def application_cached_gems
        path = ENV["BUNDLE_CACHE_PATH"] || Bundler.settings[:cache_path]
        path ? from_cached_specs(path) : purifier_original_application_cached_gems
      end
    end
  end
end

$0 = ARGV.shift
# These SDKs write their native lock as part of install, before a separate
# lock command existed. Keep resolution and lock serialization native.
legacy_install_lock = Bundler::Definition.respond_to?(:build) && !defined?(Bundler::SourceList)
if ARGV.first == "lock" && (legacy_install_lock || !Bundler::CLI.instance_methods.map { |name| name.to_s }.include?("lock"))
  ARGV[0] = "install"
end
if !Bundler::Definition.respond_to?(:build) && ARGV.first == "install" && ARGV.delete("--local")
  # This native CLI has no --local flag. Give its own resolver the local
  # source indexes, retaining native installation and conflict handling.
  require "bundler/installer"
  class Bundler::Source::Git
    # Nix supplies the exact locked tree under the later cache convention.
    # Populate this SDK's own installation path from that verified tree.
    def purifier_pinned_checkout
      ref = options["ref"]
      return nil unless ref && ref =~ /\A[0-9a-f]{40}([0-9a-f]{24})?\z/
      directory = ENV["BUNDLE_CACHE_PATH"] || Bundler.settings[:cache_path]
      return nil unless directory
      tree = Bundler.root.join(directory, "#{base_name}-#{ref[0, 12]}")
      tree.join(".bundlecache").file? ? tree : nil
    end

    def purifier_materialize_checkout
      tree = purifier_pinned_checkout
      return false unless tree
      unless @purifier_materialized_checkout
        FileUtils.mkdir_p(path)
        FileUtils.cp_r(tree.to_s + "/.", path.to_s, :remove_destination => true)
        @purifier_materialized_checkout = true
      end
      true
    end

    alias_method :purifier_original_local_specs, :local_specs
    def local_specs
      purifier_materialize_checkout
      purifier_original_local_specs
    end
    alias_method :purifier_original_checkout, :checkout
    def checkout
      purifier_original_checkout unless purifier_materialize_checkout
    end
    alias_method :purifier_original_cache, :cache
    def cache
      purifier_original_cache unless purifier_pinned_checkout
    end
    alias_method :purifier_original_revision, :revision
    def revision
      purifier_pinned_checkout ? options.fetch("ref") : purifier_original_revision
    end
    private :checkout, :cache, :revision, :purifier_materialize_checkout, :purifier_pinned_checkout
  end
  index_method = PurifierNativeIndex.installer_index_method(Bundler::Installer)
  # Both names denote the SDK's own default resolver index. Only the
  # native command lacking --local receives this local source collection.
  Bundler::Installer.class_eval <<-RUBY, __FILE__, __LINE__ + 1
    def #{index_method}
      @purifier_local_index ||= PurifierNativeIndex.local(sources)
    end
    private :#{index_method}
  RUBY
end
if !Bundler::Definition.respond_to?(:build) && ENV["BUNDLER_PURIFIER_INPUT_DATA"]
  # A locked 0.9 Definition bypasses Gemfile evaluation, so the lent facade
  # alone cannot apply its declared Nix dependency bindings.
  require File.expand_path("rubygems_inputs", File.dirname(__FILE__))
end
require File.expand_path("native_cache_path", File.dirname(__FILE__))
PurifierNativeCachePath.install
load $0
