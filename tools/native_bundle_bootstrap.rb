# SPDX-License-Identifier: MIT
# Activate the selected consumer SDK before loading its own executable.
require "rubygems"
gem "bundler", ENV.fetch("BUNDLER_PURIFIER_BUNDLER_VERSION", ">= 0")
require "bundler"
require "bundler/cli"

# Early Path::Installer stores @spec directly, while newer RubyGems'
# inherited accessor expects @package. Later Bundler supplies this reader.
unless defined?(Bundler::SourceList)
  require "bundler/source/path/installer"
  unless Bundler::Source::Path::Installer.instance_methods(false).map { |name| name.to_s }.include?("spec")
    class Bundler::Source::Path::Installer
      attr_reader :spec
    end
  end
end
# Early Bundler hard-codes vendor/cache. Honor the isolated cache setting
# through the later native convention; native app-config support is retained.
unless Bundler::Settings.method_defined?(:app_cache_path)
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

$0 = ARGV.shift
# These SDKs write their native lock as part of install, before a separate
# lock command existed. Keep resolution and lock serialization native.
if ARGV.first == "lock" && !Bundler::CLI.instance_methods.map { |name| name.to_s }.include?("lock")
  ARGV[0] = "install"
end
load $0
