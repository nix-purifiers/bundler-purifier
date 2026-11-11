require "rainbow"
require "json"
require_relative "greeting/version"

module Greeting
  def self.hello(name)
    raise "native value" unless JSON.parse('{"answer":42}').fetch("answer") == 42
    native = $LOADED_FEATURES.find { |path| path =~ /json\/ext\/parser\.(so|bundle)$/ }
    raise "parser is not from the selected gem" unless native && native.start_with?(Gem.loaded_specs.fetch("json").full_gem_path + "/")
    Rainbow("hello, #{name}").bright
  end
end
