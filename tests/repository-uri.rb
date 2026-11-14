# SPDX-License-Identifier: MIT
ENV["BUNDLE_GEMFILE"] = File.expand_path("fixtures/ruby23-bundler23/Gemfile", File.dirname(__FILE__))
require "rubygems"
gem "bundler", "=2.3.27"
require "bundler"
require "uri"
require File.expand_path("../pkgs/cli/tools/repository_uri", File.dirname(__FILE__))
repository = "file:///nix/store/fixture-repository/"
global = URI.parse(repository)
source = Bundler::Source::Rubygems.new("remotes" => [repository])
remote = source.remotes.first
abort "native URI boundary not exercised" if global.to_s == remote.to_s
original_class = remote.class
original_text = remote.to_s
expected = PurifierRepositoryURI.identity(global)
abort "equivalent native URI mismatch" unless PurifierRepositoryURI.identity(remote) == expected
["file://elsewhere/nix/store/fixture-repository/", "file:///nix/store/other/",
 "file:///nix/store/fixture-repository/?other", "file:///nix/store/fixture-repository/%2f"].each do |different|
  native = Bundler::Source::Rubygems.new("remotes" => [different]).remotes.first
  abort "different repository accepted" if PurifierRepositoryURI.identity(native) == expected
end
abort "native URI changed" unless remote.class == original_class && remote.to_s == original_text
puts "PASS genuine global/vendored URI identity and distinct host/path/query/escape controls"
