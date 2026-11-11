# SPDX-License-Identifier: MIT
require "rbconfig"
require_relative "../tools/native_environment_sdk"

runner = PurifierNativeEnvironmentSDK
ruby = RbConfig.ruby
raise "SDK command output changed" unless runner.run(ruby, "-e", 'STDOUT.write("exact bytes")') == "exact bytes"
context_keys = %w[BUNDLE_NATIVE_TEST BUNDLER_NATIVE_TEST RUBYOPT]
saved_context = context_keys.to_h { |key| [key, ENV[key]] }
begin
  context_keys.each { |key| ENV[key] = "inherited-outside-context" }
  clean = runner.clean_environment("BUNDLER_PURIFIER_NATIVE_BINDINGS" => "owned-binding-data")
  raise "SDK context was inherited" unless context_keys.all? { |key| clean.key?(key) && clean[key].nil? }
  program = 'raise if ENV["BUNDLE_NATIVE_TEST"] || ENV["BUNDLER_NATIVE_TEST"] || ENV["RUBYOPT"];raise unless ENV["BUNDLER_PURIFIER_NATIVE_BINDINGS"]=="owned-binding-data";print "clean"'
  raise "SDK owned context was lost" unless runner.run(ruby, "-e", program, env: clean) == "clean"
ensure
  saved_context.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
end
cases = [
  ["nonzero", 'exit 7', {}],
  ["live child", 'sleep 10', {deadline_seconds: 0.2}],
  ["orphan holding output", 'fork { sleep 10 }; exit 0', {deadline_seconds: 0.2}],
  ["closed pipes with live parent", 'STDOUT.close; STDERR.close; sleep 10', {deadline_seconds: 0.2}],
  ["output bound", 'STDOUT.write("x" * 2048)', {output_limit: 1024}],
]
cases.each do |label, program, options|
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  rejected = false
  begin
    runner.run(ruby, "-e", program, **options)
  rescue PurifierNativeEnvironment::Invalid
    rejected = true
  end
  raise "SDK command accepted #{label}" unless rejected
  raise "SDK command failed to bound #{label}" unless Process.clock_gettime(Process::CLOCK_MONOTONIC) - started < 3
end
puts "7 bounded SDK command/context checks passed"
