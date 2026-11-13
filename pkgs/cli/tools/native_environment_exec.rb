# SPDX-License-Identifier: MIT
# Invoke the genuine pre-lockfile SDK's public environment setup, then replace
# this process with the user's exact argv. Host validation precedes this step.
require "rubygems"
project = ARGV.shift
sdk = ARGV.shift
ARGV.shift if ARGV.first == "--"
raise "usage: native_environment_exec.rb PROJECT SDK COMMAND..." unless project && sdk && !ARGV.empty?
command = ARGV.dup
ARGV.clear
legacy = !defined?(Gem::VERSION) && defined?(Gem::RubyGemsVersion) && Gem::RubyGemsVersion == "1.0.1" && RUBY_VERSION == "1.8.3"
gem "bundler", legacy ? "= 0.3.1" : "= 0.8.1"
require "bundler"
valid = legacy ? Bundler::VERSION == "0.5.0" : (Gem::VERSION == "1.3.5" && Bundler::VERSION == "0.8.1")
raise "bundler-purifier: wrong native execution SDK" unless valid
ENV["PATH"] = File.join(sdk, "bin") + File::PATH_SEPARATOR + ENV["PATH"].to_s
if legacy
  require File.expand_path("native_environment_observe", File.dirname(__FILE__))
  require File.expand_path("native_environment_v03_layout", File.dirname(__FILE__))
  project = Pathname.new(project).realpath.to_s
  archives = PurifierEnvironmentObservation.input_archives(project)
  manifest = PurifierNativeV03Layout.activation(project, archives)
  manifest.setup_environment
  ENV["PATH"] = [File.join(sdk, "bin"), manifest.bindir.to_s, Gem.bindir(manifest.gem_path.to_s), ENV["PATH"]].join(File::PATH_SEPARATOR)
else
  Bundler::Bundle.load(File.join(project, "Gemfile")).setup_environment
end
ENV["BUNDLER_PURIFIER_NATIVE_OPERATION"] = "runtime" if ENV["BUNDLER_PURIFIER_NATIVE_BINDINGS"]
exec(*command)
