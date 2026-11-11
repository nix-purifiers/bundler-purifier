# SPDX-License-Identifier: MIT
# Keep native cache cleanup on Rubies whose Dir[] requires to_str, before
# it accepted Pathname's to_path interface. Only the selected cache objects
# receive string coercion; the SDK's classes and cache algorithm stay native.
module PurifierNativeCachePath
  module StringCoercion
    def to_str
      to_s
    end

    def join(*arguments)
      PurifierNativeCachePath.decorate(super)
    end
  end

  def self.decorate(path)
    path.is_a?(Pathname) ? path.extend(StringCoercion) : path
  end

  def self.install
    return if @installed || !Bundler.respond_to?(:app_cache)
    return unless ENV["BUNDLE_CACHE_PATH"] || ENV["BUNDLER_PURIFIER_INPUT_DATA"]
    begin
      Dir[Pathname.new("__purifier_cache_path_probe__")]
      return
    rescue TypeError
      # This runtime needs the older string-coercion protocol.
    end
    eigenclass = class << Bundler; self; end
    eigenclass.send(:alias_method, :purifier_original_app_cache_string_path, :app_cache)
    eigenclass.class_eval do
      def app_cache(*arguments)
        PurifierNativeCachePath.decorate(purifier_original_app_cache_string_path(*arguments))
      end
    end
    @installed = true
  end
end
