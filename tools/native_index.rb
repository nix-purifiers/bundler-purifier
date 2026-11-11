# SPDX-License-Identifier: MIT
# Construct and combine genuine native indexes through the available SDK API.
module PurifierNativeIndex
  def self.build
    if Bundler::Index.respond_to?(:build)
      Bundler::Index.build { |index| yield index }
    else
      index = Bundler::Index.new
      yield index
      index
    end
  end

  def self.use(index, other)
    index.respond_to?(:use) ? index.use(other) : index.merge!(other)
  end

  def self.installed
    Bundler::Index.respond_to?(:installed_gems) ? Bundler::Index.installed_gems : Bundler::Index.from_installed_gems
  end

  def self.cached
    return Bundler::Index.cached_gems if Bundler::Index.respond_to?(:cached_gems)
    Bundler::Index.from_cached_specs(Bundler.load.send(:cache_path))
  end
end
