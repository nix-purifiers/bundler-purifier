# SPDX-License-Identifier: MIT
# Capture and offline candidate regeneration. Activation and working-state
# receipts belong to a separate validation step; this helper never activates a
# captured snapshot. Regeneration must run in a Nix network-isolated builder.
require "fileutils"
require_relative "native_environment_sdk"

module PurifierNativeEnvironmentPrepare
  CONTRACT = PurifierNativeEnvironment
  SDK = PurifierNativeEnvironmentSDK
  CLEAN_ENV = {"RUBYOPT" => nil, "RUBYLIB" => nil, "GEM_HOME" => nil, "GEM_PATH" => nil}.freeze

  def self.snapshot(project, relative)
    CONTRACT.path!(relative)
    path = File.realpath(File.join(project, relative))
    CONTRACT.reject!("native evidence escapes project role") unless path.start_with?(project + "/")
    CONTRACT.reject!("native snapshot exceeds size limit") unless File.file?(path) && File.size(path) <= CONTRACT::MAX_SNAPSHOT
    bytes = File.binread(path)
    {"path" => relative, "size" => bytes.bytesize, "sha256" => CONTRACT.hash_bytes(bytes),
     "base64" => Base64.strict_encode64(bytes)}.tap { |record| CONTRACT.snapshot!(record) }
  end

  def self.capture(project, sdk, identity: nil, project_gemspecs: [])
    project = File.realpath(project)
    CONTRACT.reject!("ambiguous Gemfile.lock for pre-lockfile SDK") if File.exist?(File.join(project, "Gemfile.lock")) || File.symlink?(File.join(project, "Gemfile.lock"))
    identity ||= SDK.attest(sdk)
    observer = File.join(__dir__, "native_environment_observe.rb")
    observation = JSON.parse(SDK.run(File.join(sdk, "bin/ruby"), observer, project, env: CLEAN_ENV, cwd: project))
    CONTRACT.exact!(observation, %w[packages rootRequirements generatedPaths], "native environment observation")
    manifests = (["Gemfile"] + project_gemspecs).uniq.sort.map { |path| snapshot(project, path) }
    result = {"format" => "bundler-native-environment", "schemaVersion" => 1,
              "interface" => "environment-v08", "nativeLockFile" => nil,
              "contexts" => ["default"], "sdk" => identity, "manifests" => manifests,
              "snapshots" => observation.fetch("generatedPaths").map { |path| snapshot(project, path) },
              "packages" => observation.fetch("packages"), "rootRequirements" => observation.fetch("rootRequirements")}
    CONTRACT.validate!(result)
  end

  def self.regenerate(expected, sdk, archives, destination, closure_paths: nil)
    CONTRACT.validate!(expected)
    identity = SDK.attest(sdk, closure_paths: closure_paths)
    CONTRACT.reject!("native replay SDK differs from capture") unless CONTRACT.canonical(identity) == CONTRACT.canonical(expected.fetch("sdk"))
    packages = expected.fetch("packages")
    CONTRACT.reject!("native replay archive set differs from capture") unless archives.is_a?(Hash) && archives.keys.sort == packages.map { |package| package.fetch("name") }.sort
    verified = packages.to_h do |package|
      archive = File.realpath(archives.fetch(package.fetch("name")))
      CONTRACT.reject!("native replay archive is not regular") unless File.file?(archive)
      CONTRACT.reject!("native replay archive bytes differ from capture") unless CONTRACT.hash_file(archive) == package.fetch("archiveHash")
      [package.fetch("name"), archive]
    end
    destination = File.join(File.realpath(File.dirname(destination)), File.basename(destination))
    CONTRACT.reject!("native regeneration destination already exists") if File.exist?(destination) || File.symlink?(destination)
    Dir.mkdir(destination, 0700)
    expected.fetch("manifests").each do |record|
      path = File.join(destination, record.fetch("path"))
      FileUtils.mkdir_p(File.dirname(path), mode: 0700)
      File.binwrite(path, Base64.strict_decode64(record.fetch("base64")))
    end
    # Cache and resolve through the genuine plugin. --cached selects only
    # native local sources; Nix supplies the network isolation for Ruby code.
    verified.each_value do |archive|
      SDK.run(File.join(sdk, "bin/gem"), "bundle", "--cache", archive, env: CLEAN_ENV, cwd: destination)
    end
    SDK.run(File.join(sdk, "bin/gem"), "bundle", "--cached", env: CLEAN_ENV, cwd: destination)
    fresh = capture(destination, sdk, identity: identity,
                    project_gemspecs: expected.fetch("manifests").map { |record| record.fetch("path") } - ["Gemfile"])
    CONTRACT.compare_observation!(expected, fresh)
    fresh
  end
end

if __FILE__ == $0
  mode = ARGV.shift
  case mode
  when "capture"
    raise "usage: native_environment_prepare.rb capture PROJECT SDK" unless ARGV.size == 2
    result = PurifierNativeEnvironmentPrepare.capture(*ARGV)
  when "regenerate"
    raise "usage: native_environment_prepare.rb regenerate RECORD SDK ARCHIVES DESTINATION [CLOSURE-PATHS]" unless ARGV.size.between?(4, 5)
    record, sdk, archive_file, destination, closure_file = ARGV
    expected = PurifierNativeEnvironment.parse(File.binread(record, PurifierNativeEnvironment::MAX_DOCUMENT + 1))
    archive_bytes = File.binread(archive_file, PurifierNativeEnvironment::MAX_DOCUMENT + 1)
    PurifierNativeEnvironment.reject!("archive transport map exceeds size limit") if archive_bytes.bytesize > PurifierNativeEnvironment::MAX_DOCUMENT
    archives = JSON.parse(archive_bytes, object_class: PurifierNativeEnvironment::UniqueObject)
    closure_paths = closure_file ? File.readlines(closure_file, chomp: true).reject(&:empty?) : nil
    result = PurifierNativeEnvironmentPrepare.regenerate(expected, sdk, archives, destination, closure_paths: closure_paths)
  else
    raise "expected capture or regenerate"
  end
  puts JSON.generate(PurifierNativeEnvironment.canonical(result))
end
