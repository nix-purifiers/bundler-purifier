# SPDX-License-Identifier: MIT
# Host helper view of source facts decoded by the selected native YAML SDK.
require "digest"
require "base64"

module PurifierNativeLock
  class Invalid < StandardError; end
  GUIDANCE = "recapture with the intended native SDK using bundler-purifier lock --force"
  KEYS = %w[gemSources gitSources pathSources checksums bundledWith rubyVersion].sort.freeze

  def self.yaml?(text)
    text.lstrip.index("---") == 0
  end

  def self.reject!(reason)
    raise Invalid, "bundler-purifier: #{reason}; #{GUIDANCE}"
  end

  def self.scalar?(value)
    value.is_a?(String) && !value.empty? && !value.match?(/[\r\n]/)
  end

  def self.validate(text, snapshot, bundler_version: nil, ruby_version: nil)
    reject!("native YAML lock lacks bundlerNativeLock") unless snapshot.is_a?(Hash)
    reject!("unsupported native snapshot fields") unless snapshot.keys.sort == %w[format nativeHash observed parsed].sort
    reject!("native snapshot format conflicts with Gemfile.lock") unless yaml?(text) && snapshot["format"] == "bundler-yaml"
    expected = "sha256-#{Base64.strict_encode64(Digest::SHA256.digest(text))}"
    reject!("native snapshot hash is stale or mismatched") unless snapshot["nativeHash"] == expected
    sdk = snapshot["observed"]
    reject!("native snapshot SDK identity is incomplete") unless sdk.is_a?(Hash) && sdk.keys.sort == %w[ruby patchlevel rubygems bundler platform].sort &&
      %w[ruby rubygems bundler platform].all? { |key| scalar?(sdk[key]) } && sdk["patchlevel"].is_a?(Integer)
    reject!("native snapshot SDK identity conflicts with bundlerVersion") if bundler_version && sdk["bundler"] != bundler_version
    reject!("native snapshot SDK identity conflicts with ruby") if ruby_version && sdk["ruby"] != ruby_version
    parsed = snapshot["parsed"]
    reject!("native snapshot parsed source shape is invalid") unless parsed.is_a?(Hash) && parsed.keys.sort == KEYS &&
      parsed["checksums"] == {} && parsed["bundledWith"].nil? && parsed["rubyVersion"].nil?
    %w[gemSources gitSources pathSources].each do |kind|
      sources = parsed[kind]
      reject!("native snapshot source list is invalid") unless sources.is_a?(Array)
      sources.each do |source|
        reject!("native snapshot source record is invalid") unless source.is_a?(Hash) && source.keys.sort == %w[fields remotes specs] &&
          source["fields"].is_a?(Hash) && source["fields"].all? { |key, value| scalar?(key) && scalar?(value) } &&
          source["remotes"].is_a?(Array) && !source["remotes"].empty? && source["remotes"].all? { |value| scalar?(value) } &&
          source["fields"]["remote"] == source["remotes"].last && source["specs"].is_a?(Array)
        reject!("native snapshot Git revision is missing") if kind == "gitSources" && !scalar?(source["fields"]["revision"])
        source["specs"].each do |spec|
          reject!("native snapshot selected specification is invalid") unless spec.is_a?(Hash) && spec.keys.sort == %w[name version] &&
            scalar?(spec["name"]) && scalar?(spec["version"]) && !spec["name"].match?(/\s/) && !spec["version"].match?(/\s/)
        end
      end
    end
    snapshot
  end

  def self.parser(text, snapshot, **identity)
    validate(text, snapshot, **identity)
    # This is an in-memory graph adapter for the host helper's existing
    # source objects. The SDK's YAML file is never converted or rewritten.
    sections = []
    { "gemSources" => "GEM", "gitSources" => "GIT", "pathSources" => "PATH" }.each do |kind, header|
      snapshot.fetch("parsed").fetch(kind).each do |source|
        lines = [header]
        source.fetch("remotes").each { |remote| lines << "  remote: #{remote}" }
        source.fetch("fields").each { |key, value| lines << "  #{key}: #{value}" unless key == "remote" }
        lines << "  specs:"
        source.fetch("specs").each { |spec| lines << "    #{spec.fetch('name')} (#{spec.fetch('version')})" }
        sections << lines.join("\n")
      end
    end
    sections << "PLATFORMS\n  #{snapshot.fetch('observed').fetch('platform')}"
    Bundler::LockfileParser.new(sections.join("\n\n") + "\n")
  end
end
