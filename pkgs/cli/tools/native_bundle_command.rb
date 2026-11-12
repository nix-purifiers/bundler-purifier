# SPDX-License-Identifier: MIT
require File.expand_path("native_bundle", File.dirname(__FILE__))
require "rubygems"
requested_bundler = ENV.fetch("BUNDLER_PURIFIER_BUNDLER_VERSION", ">= 0")
gem "bundler", requested_bundler
require "bundler"
require "bundler/definition"
native_lock_format = Bundler::Definition.respond_to?(:build) ? "text" : "yaml"
views = JSON.parse(ENV.fetch("BUNDLER_PURIFIER_INPUT_VIEWS", "[]"))
persist = ENV["BUNDLER_PURIFIER_PERSIST_LOCK"] == "1"
result = PurifierNativeBundle.run(ARGV, :root => Dir.pwd, :views => views,
                                 :ruby => Gem.ruby, :bundle => Gem.bin_path("bundler", "bundle", requested_bundler),
                                 :persist_lock => persist, :lock_format => native_lock_format)
exit(result ? 0 : (($? && $?.exitstatus) || 1))
