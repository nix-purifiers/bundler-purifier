# SPDX-License-Identifier: MIT
# Activate the selected consumer SDK before loading its own executable.
require "rubygems"
gem "bundler", ENV.fetch("BUNDLER_PURIFIER_BUNDLER_VERSION", ">= 0")
require "bundler"
require "bundler/cli"

# Early Bundler hard-codes vendor/cache and .bundle/config. Honor the
# purifier's isolated native settings using the later native conventions.
unless Bundler.respond_to?(:app_config_path)
  class Bundler::Settings
    alias_method :purifier_original_local_config_file, :local_config_file
    def local_config_file
      return Pathname.new(ENV["BUNDLE_APP_CONFIG"]).join("config") if ENV["BUNDLE_APP_CONFIG"]
      purifier_original_local_config_file
    end
    private :local_config_file
  end
end
unless Bundler::Settings.method_defined?(:app_cache_path)
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
