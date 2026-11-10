# SPDX-License-Identifier: MIT
require File.expand_path("native_bundle", File.dirname(__FILE__))
require "rubygems"
views = JSON.parse(ENV.fetch("BUNDLER_PURIFIER_INPUT_VIEWS", "[]"))
persist = ENV["BUNDLER_PURIFIER_PERSIST_LOCK"] == "1"
result = PurifierNativeBundle.run(ARGV, :root => Dir.pwd, :views => views,
                                 :ruby => Gem.ruby, :bundle => Gem.bin_path("bundler", "bundle", ENV.fetch("BUNDLER_PURIFIER_BUNDLER_VERSION", ">= 0")),
                                 :persist_lock => persist)
exit(result ? 0 : (($? && $?.exitstatus) || 1))
