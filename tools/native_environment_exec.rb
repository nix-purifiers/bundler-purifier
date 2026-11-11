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
gem "bundler", "= 0.8.1"
require "bundler"
raise "bundler-purifier: wrong native execution SDK" unless Gem::VERSION == "1.3.5" && Bundler::VERSION == "0.8.1"
ENV["PATH"] = File.join(sdk, "bin") + File::PATH_SEPARATOR + ENV["PATH"].to_s
Bundler::Bundle.load(File.join(project, "Gemfile")).setup_environment
ENV["BUNDLER_PURIFIER_NATIVE_OPERATION"] = "runtime" if ENV["BUNDLER_PURIFIER_NATIVE_BINDINGS"]
exec(*command)
