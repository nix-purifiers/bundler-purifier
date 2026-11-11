# SPDX-License-Identifier: MIT
# Host-side validation of pre-lockfile native observations. This helper never
# evaluates captured Ruby or substitutes objects for the selected SDK.
require "json"
require "digest"
require "base64"

module PurifierNativeEnvironment
  class Invalid < StandardError; end
  MAX_DOCUMENT = 16 * 1024 * 1024
  MAX_SNAPSHOT = 1024 * 1024
  MAX_RECORDS = 4096
  MAX_EVIDENCE_ENCODED = 8 * 1024 * 1024
  MAX_EVIDENCE_DECODED = 6 * 1024 * 1024

  class UniqueObject < Hash
    def []=(key, value)
      raise Invalid, "duplicate JSON field: #{key}" if key?(key)
      super
    end
  end

  def self.reject!(message)
    raise Invalid, "bundler-purifier: #{message}"
  end

  def self.canonical(value)
    case value
    when Hash then value.keys.sort.to_h { |key| [key, canonical(value.fetch(key))] }
    when Array then value.map { |item| canonical(item) }
    else value
    end
  end

  def self.hash_bytes(bytes)
    "sha256-#{Base64.strict_encode64(Digest::SHA256.digest(bytes))}"
  end

  def self.hash_file(path)
    "sha256-#{Base64.strict_encode64(Digest::SHA256.file(path).digest)}"
  end

  def self.content_hash(document)
    hash_bytes(JSON.generate(canonical(document.reject { |key, _| key == "contentHash" })))
  end

  def self.parse(bytes)
    reject!("native environment document exceeds size limit") if bytes.bytesize > MAX_DOCUMENT
    value = JSON.parse(bytes, object_class: UniqueObject, max_nesting: 64)
    reject!("native environment JSON must use canonical encoding") unless bytes == JSON.generate(canonical(value)) + "\n"
    value
  rescue JSON::ParserError, JSON::NestingError => error
    reject!("invalid native environment JSON: #{error.message}")
  end

  def self.exact!(value, keys, label)
    reject!("invalid #{label} fields") unless value.is_a?(Hash) && value.keys.sort == keys.sort
  end

  def self.scalar!(value, label)
    reject!("invalid #{label}") unless value.is_a?(String) && !value.empty? && value.bytesize <= 4096 && !value.match?(/[\x00-\x1f\x7f]/)
  end

  def self.digest!(value)
    reject!("invalid SHA-256 identity") unless value.is_a?(String) && value.match?(/\Asha256-[A-Za-z0-9+\/]{43}=\z/) && Base64.strict_encode64(Base64.strict_decode64(value.delete_prefix("sha256-"))) == value.delete_prefix("sha256-")
  rescue ArgumentError
    reject!("invalid SHA-256 identity")
  end

  def self.path!(value)
    scalar!(value, "relative native path")
    reject!("unsafe relative native path") if value.start_with?("/") || value.split("/", -1).any? { |part| part.empty? || part == "." || part == ".." } || value.include?("\\")
  end

  def self.load_path!(value)
    return if value == "."
    path!(value)
  end

  def self.list!(value, label)
    reject!("invalid #{label} collection") unless value.is_a?(Array) && value.size <= MAX_RECORDS
  end

  def self.unique!(values, label)
    reject!("duplicate #{label}") unless values.uniq.size == values.size
  end

  def self.snapshot!(value)
    exact!(value, %w[path size sha256 base64], "native snapshot")
    path!(value.fetch("path"))
    size = value.fetch("size")
    reject!("invalid native snapshot size") unless size.is_a?(Integer) && size.between?(0, MAX_SNAPSHOT)
    encoded = value.fetch("base64")
    reject!("invalid bounded native snapshot encoding") unless encoded.is_a?(String) && encoded.bytesize == 4 * ((size + 2) / 3)
    begin
      bytes = Base64.strict_decode64(encoded)
    rescue ArgumentError
      reject!("invalid native snapshot base64")
    end
    reject!("noncanonical native snapshot encoding") unless Base64.strict_encode64(bytes) == encoded
    reject!("native Ruby text contains NUL") if bytes.include?("\0")
    digest!(value.fetch("sha256"))
    reject!("native snapshot bytes conflict with identity") unless bytes.bytesize == size && hash_bytes(bytes) == value.fetch("sha256")
  end

  def self.sdk!(value)
    exact!(value, %w[ruby patchlevel abi platform interpreter components clientArtifact clientReport rubygemsReport closure], "native SDK")
    %w[ruby abi platform].each { |key| scalar!(value.fetch(key), key) }
    patch = value.fetch("patchlevel")
    reject!("invalid native patchlevel") unless %w[1.8.3 1.8.4].include?(value.fetch("ruby")) ? patch.nil? : (patch.is_a?(Integer) && patch.between?(-1, 1_000_000))
    digest!(value.fetch("interpreter"))
    closure = value.fetch("closure")
    list!(closure, "SDK runtime closure")
    reject!("missing SDK runtime closure") if closure.empty?
    closure.each do |entry|
      exact!(entry, %w[path narHash], "SDK runtime closure entry")
      scalar!(entry.fetch("path"), "SDK runtime path")
      reject!("invalid SDK runtime path") unless entry.fetch("path").match?(%r{\A/nix/store/[a-z0-9]{32}-[^/]+\z})
      digest!(entry.fetch("narHash"))
    end
    unique!(closure.map { |entry| entry.fetch("path") }, "SDK runtime closure entry")
    components = value.fetch("components")
    list!(components, "SDK component")
    reject!("missing SDK components") if components.empty?
    components.each do |component|
      exact!(component, %w[name version archiveHash libraryHash], "SDK component")
      %w[name version].each { |key| scalar!(component.fetch(key), key) }
      %w[archiveHash libraryHash].each { |key| digest!(component.fetch(key)) }
    end
    unique!(components.map { |component| component.fetch("name") }, "SDK component")
    reject!("incomplete SDK runtime closure") unless (%w[ruby rubygems bundler json] - components.map { |component| component.fetch("name") }).empty?
    artifact = value.fetch("clientArtifact")
    exact!(artifact, %w[name version archiveHash libraryHash], "native client artifact")
    reject!("client artifact is not in SDK closure") unless artifact.fetch("name") == "bundler" && components.include?(artifact)
    %w[clientReport rubygemsReport].each do |key|
      report = value.fetch(key)
      exact!(report, %w[name value], key)
      scalar!(report.fetch("value"), key)
    end
    profiles = {
      "0.8.1" => ["0.8.1", "Gem::VERSION", "1.3.5", "1.8.6"],
      "0.3.1" => ["0.5.0", "Gem::RubyGemsVersion", "1.0.1", "1.1.3"]
    }
    profile = profiles[artifact.fetch("version")]
    reject!("unsupported native interface identity") unless profile && value.fetch("clientReport") == {"name" => "Bundler::VERSION", "value" => profile[0]} && value.fetch("rubygemsReport") == {"name" => profile[1], "value" => profile[2]}
    reject!("RubyGems component conflicts with observed version") unless components.any? { |component| component.fetch("name") == "rubygems" && component.fetch("version") == profile[2] }
    reject!("JSON component conflicts with native profile") unless components.any? { |component| component.fetch("name") == "json" && component.fetch("version") == profile[3] }
    reject!("unsupported early native runtime") if artifact.fetch("version") == "0.3.1" && value.fetch("ruby") != "1.8.3"
  end

  # This validates the new nativeResolution record only. Existing v3 readers
  # and writers retain their own contract and do not pass through this helper.
  def self.validate!(value)
    exact!(value, %w[format schemaVersion interface nativeLockFile contexts sdk manifests snapshots packages rootRequirements bindingAlgorithm bindings], "native resolution")
    reject!("native environment document exceeds size limit") if JSON.generate(value).bytesize > MAX_DOCUMENT
    reject!("unsupported native environment format") unless value.fetch("format") == "bundler-native-environment" && value.fetch("schemaVersion").is_a?(Integer) && value.fetch("schemaVersion") == 1 && %w[environment-v08 environment-v03].include?(value.fetch("interface"))
    reject!("pre-lockfile resolution cannot contain a native lockfile") unless value.fetch("nativeLockFile").nil?
    reject!("unsupported native contexts") unless value.fetch("contexts") == ["default"]
    reject!("unsupported native binding algorithm") unless value.fetch("bindingAlgorithm") == "declared-runtime-requirements-v1"
    bindings!(value.fetch("bindings"))
    sdk!(value.fetch("sdk"))
    legacy = value.fetch("interface") == "environment-v03"
    reject!("native interface conflicts with SDK client artifact") unless value.fetch("sdk").fetch("clientArtifact").fetch("version") == (legacy ? "0.3.1" : "0.8.1")
    evidence = %w[manifests snapshots].flat_map do |key|
      list!(value.fetch(key), key)
      value.fetch(key)
    end
    encoded_total = 0
    decoded_total = 0
    evidence.each do |record|
      exact!(record, %w[path size sha256 base64], "native snapshot")
      reject!("invalid bounded native snapshot") unless record.fetch("base64").is_a?(String) && record.fetch("size").is_a?(Integer) && record.fetch("size").between?(0, MAX_SNAPSHOT)
      encoded_total += record.fetch("base64").bytesize
      decoded_total += record.fetch("size")
    end
    reject!("native evidence exceeds aggregate size limit") if encoded_total > MAX_EVIDENCE_ENCODED || decoded_total > MAX_EVIDENCE_DECODED
    %w[manifests snapshots].each do |key|
      records = value.fetch(key)
      list!(records, key)
      reject!("missing native #{key}") if records.empty?
      records.each { |record| snapshot!(record) }
      unique!(records.map { |record| record.fetch("path") }, key)
    end
    reject!("missing original Gemfile") unless value.fetch("manifests").any? { |record| record.fetch("path") == "Gemfile" }
    packages = value.fetch("packages")
    list!(packages, "native package")
    packages.each do |package|
      exact!(package, %w[name version platform dependencies archiveHash installedPath specificationPath requirePaths bindir sourceKind] + (legacy ? ["executables"] : []), "native package")
      if legacy
        list!(package.fetch("executables"), "native executable")
        package.fetch("executables").each do |name|
          reject!("unsafe native executable") unless name.is_a?(String) && name.match?(/\A[A-Za-z0-9_.-]+\z/) && !%w[. ..].include?(name)
        end
        unique!(package.fetch("executables"), "native executable")
      end
      %w[name version platform].each { |key| scalar!(package.fetch(key), key) }
      digest!(package.fetch("archiveHash"))
      path!(package.fetch("installedPath"))
      path!(package.fetch("specificationPath"))
      list!(package.fetch("requirePaths"), "native load path")
      package.fetch("requirePaths").each { |path| load_path!(path) }
      load_path!(package.fetch("bindir")) unless package.fetch("bindir").nil?
      reject!("unsupported native source kind") unless package.fetch("sourceKind") == (legacy ? "verified-input" : "verified-cache")
      dependencies = package.fetch("dependencies")
      list!(dependencies, "native dependency")
      dependencies.each do |dependency|
        exact!(dependency, %w[name requirements type], "native dependency")
        scalar!(dependency.fetch("name"), "dependency name")
        reject!("unsupported native dependency type") unless %w[runtime development].include?(dependency.fetch("type"))
        requirements = dependency.fetch("requirements")
        list!(requirements, "native requirement")
        reject!("missing native requirement") if requirements.empty?
        requirements.each { |requirement| scalar!(requirement, "native requirement") }
        unique!(requirements, "native requirement")
      end
      unique!(dependencies.map { |dependency| [dependency.fetch("name"), dependency.fetch("type")] }, "native dependency")
    end
    unique!(packages.map { |package| package.fetch("name") }, "native selected package")
    value.fetch("bindings").each do |binding|
      selected = packages.find { |package| package.fetch("name") == binding.fetch("name") }
      reject!("native binding differs from selected package") if selected && selected.fetch("version") != binding.fetch("version")
    end
    roots = value.fetch("rootRequirements")
    list!(roots, "native root requirement")
    roots.each do |root|
      exact!(root, %w[name requirements], "native root requirement")
      scalar!(root.fetch("name"), "native root name")
      clauses = root.fetch("requirements")
      list!(clauses, "native root constraint")
      reject!("missing native root constraint") if clauses.empty?
      clauses.each { |clause| scalar!(clause, "native root constraint") }
      unique!(clauses, "native root constraint")
      reject!("missing native root selection") unless packages.any? { |candidate| candidate.fetch("name") == root.fetch("name") }
    end
    unique!(roots.map { |root| root.fetch("name") }, "native root requirement")
    packages.each do |package|
      package.fetch("dependencies").each do |dependency|
        next unless dependency.fetch("type") == "runtime"
        reject!("incomplete native runtime closure") unless packages.any? { |candidate| candidate.fetch("name") == dependency.fetch("name") }
      end
    end
    reachable = []
    pending = roots.map { |root| root.fetch("name") }
    until pending.empty?
      name = pending.pop
      next if reachable.include?(name)
      reachable << name
      package = packages.find { |candidate| candidate.fetch("name") == name }
      package.fetch("dependencies").each do |dependency|
        pending << dependency.fetch("name") if dependency.fetch("type") == "runtime"
      end
    end
    reject!("native selected closure contains an unrelated package") unless reachable.sort == packages.map { |package| package.fetch("name") }.sort
    prefix = legacy ? "vendor/gems/" : "vendor/gems/ruby/#{value.fetch('sdk').fetch('abi')}/"
    path!(prefix.delete_suffix("/"))
    required_snapshots = legacy ? ["vendor/gems/environments/default.rb"] : ["vendor/gems/environment.rb", prefix + "environment.rb"]
    if legacy
      wrappers = packages.flat_map { |package| package.fetch("executables") }
      unique!(wrappers, "native wrapper owner")
      required_snapshots.concat(wrappers.map { |name| "vendor/gems/bin/" + name })
    end
    packages.each do |package|
      installed_prefix = prefix + "gems/"
      installed = package.fetch("installedPath")
      reject!("native installed role conflicts with SDK layout") unless installed.start_with?(installed_prefix) && !installed.delete_prefix(installed_prefix).include?("/")
      expected_specification = prefix + "specifications/" + installed.delete_prefix(installed_prefix) + ".gemspec"
      reject!("native specification role conflicts with installed package") unless package.fetch("specificationPath") == expected_specification
      required_snapshots << expected_specification
      unless package.fetch("requirePaths") == ["lib"] && [nil, "bin"].include?(package.fetch("bindir"))
        required_snapshots << installed + "/.require_paths"
      end
    end
    reject!("native snapshot inventory is incomplete or unexpected") unless required_snapshots.sort == value.fetch("snapshots").map { |record| record.fetch("path") }.sort
    value
  end

  def self.bindings!(bindings)
    list!(bindings, "declared native binding")
    bindings.each do |binding|
      exact!(binding, %w[name version], "declared native binding")
      name, version = binding.values_at("name", "version")
      reject!("invalid declared native binding name") unless name.is_a?(String) && name.match?(/\A[A-Za-z0-9_.-]+\z/) && name != "." && name != ".." && name.bytesize <= 512
      reject!("invalid declared native binding version") unless version.is_a?(String) && version.match?(/\A[0-9A-Za-z_.-]+\z/) && version.bytesize <= 4096
    end
    unique!(bindings.map { |binding| binding.fetch("name") }, "declared native binding")
    reject!("native binding data exceeds limit") if bindings.sum { |binding| binding.fetch("name").bytesize + binding.fetch("version").bytesize + 2 } > 1048576
  end

  # Compare semantic observations, retaining original order only where the
  # native protocol gives it meaning. Packages/roots/components and conjunctive
  # requirements are sets; raw manifest bytes and SDK identity are exact.
  # This does not authorize activation or validate a working-state receipt.
  def self.compare_observation!(captured, fresh)
    validate!(captured)
    validate!(fresh)
    normalize = lambda do |record|
      result = JSON.parse(JSON.generate(record))
      result.fetch("sdk").fetch("components").sort_by! { |component| component.fetch("name") }
      result.fetch("sdk").fetch("closure").sort_by! { |entry| entry.fetch("path") }
      %w[manifests snapshots].each { |key| result.fetch(key).sort_by! { |item| item.fetch("path") } }
      result.fetch("packages").each do |package|
        package.fetch("dependencies").each { |dependency| dependency.fetch("requirements").sort! }
        package.fetch("dependencies").sort_by! { |dependency| [dependency.fetch("name"), dependency.fetch("type")] }
      end
      result.fetch("packages").sort_by! { |package| package.fetch("name") }
      result.fetch("rootRequirements").each { |root| root.fetch("requirements").sort! }
      result.fetch("rootRequirements").sort_by! { |root| root.fetch("name") }
      result.fetch("bindings").sort_by! { |binding| binding.fetch("name") }
      # Regenerated native code can contain the current workspace path. Keep
      # captured snapshots intact; compare their semantic observation instead.
      result.delete("snapshots")
      result
    end
    reject!("native regenerated environment conflicts with captured resolution") unless normalize.call(captured) == normalize.call(fresh)
    fresh
  end
end
