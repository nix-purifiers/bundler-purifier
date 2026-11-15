# SPDX-License-Identifier: MIT
# Ruby-owned v4 envelope. Existing v3 lock readers and writers stay separate.
require_relative "native_environment"

module PurifierNativeEnvironmentLock
  CONTRACT = PurifierNativeEnvironment
  KEYS = %w[version contentHash definitionHash nativeResolution projectInputs archives projectSpecs].freeze

  def self.definition_hash(resolution)
    digest = Digest::SHA256.new
    resolution.fetch("manifests").sort_by { |record| record.fetch("path") }.each do |record|
      bytes = Base64.strict_decode64(record.fetch("base64"))
      digest << "#{record.fetch('path')}\n#{bytes.bytesize}\n" << bytes << "\n"
    end
    "sha256-#{Base64.strict_encode64(digest.digest)}"
  end

  def self.filename!(value)
    CONTRACT.scalar!(value, "native archive filename")
    CONTRACT.reject!("invalid native archive filename") if value.match?(%r{[\s/\\]}) || %w[. ..].include?(value)
  end

  def self.project_specs!(specs, resolution)
    CONTRACT.list!(specs, "root project specification")
    specs.each do |spec|
      CONTRACT.exact!(spec, %w[path name version platform fullName executables bindir requirePaths dependencies], "root project specification")
      CONTRACT.path!(spec.fetch("path"))
      CONTRACT.reject!("root project specification path needs .gemspec") unless spec.fetch("path").end_with?(".gemspec")
      %w[name version platform fullName].each { |key| filename!(spec.fetch(key)) }
      CONTRACT.list!(spec.fetch("executables"), "root executable")
      spec.fetch("executables").each { |name| filename!(name) }
      CONTRACT.unique!(spec.fetch("executables"), "root executable")
      CONTRACT.reject!("native Gem095 executables require bin payloads") if resolution.fetch("sdk").fetch("rubygemsReport").fetch("value") == "0.9.5" && !spec.fetch("executables").empty? && spec.fetch("bindir") != "bin"
      CONTRACT.list!(spec.fetch("requirePaths"), "root load path")
      spec.fetch("requirePaths").each { |path| CONTRACT.load_path!(path) }
      CONTRACT.load_path!(spec.fetch("bindir")) unless spec.fetch("bindir").nil?
      CONTRACT.list!(spec.fetch("dependencies"), "root dependency")
      spec.fetch("dependencies").each do |dependency|
        CONTRACT.exact!(dependency, %w[name requirements type], "root dependency")
        filename!(dependency.fetch("name"))
        CONTRACT.reject!("unsupported root dependency type") unless %w[runtime development].include?(dependency.fetch("type"))
        clauses = dependency.fetch("requirements")
        CONTRACT.list!(clauses, "root requirement")
        CONTRACT.reject!("missing root requirement") if clauses.empty?
        clauses.each { |clause| CONTRACT.scalar!(clause, "root requirement") }
        CONTRACT.unique!(clauses, "root requirement")
      end
      CONTRACT.unique!(spec.fetch("dependencies").map { |dependency| [dependency.fetch("name"), dependency.fetch("type")] }, "root dependency")
    end
    CONTRACT.unique!(specs.map { |spec| spec.fetch("name") }, "root project name")
    CONTRACT.unique!(specs.map { |spec| spec.fetch("path") }, "root project path")
    paths = resolution.fetch("manifests").map { |record| record.fetch("path") }.select { |path| path.end_with?(".gemspec") }
    CONTRACT.reject!("root project specification inventory differs from manifests") unless paths.sort == specs.map { |spec| spec.fetch("path") }.sort
  end

  def self.validate!(document)
    CONTRACT.exact!(document, KEYS, "pre-lockfile v4 envelope")
    CONTRACT.reject!("unsupported pre-lockfile lock version") unless document.fetch("version").is_a?(Integer) && document.fetch("version") == 4
    CONTRACT.reject!("native environment document exceeds size limit") if JSON.generate(document).bytesize > CONTRACT::MAX_DOCUMENT
    CONTRACT.digest!(document.fetch("contentHash"))
    CONTRACT.reject!("pre-lockfile lock contentHash is stale") unless CONTRACT.content_hash(document) == document.fetch("contentHash")
    resolution = CONTRACT.validate!(document.fetch("nativeResolution"))
    CONTRACT.reject!("pre-lockfile definition hash is stale") unless document.fetch("definitionHash") == definition_hash(resolution)
    inputs = document.fetch("projectInputs")
    CONTRACT.list!(inputs, "project input")
    inputs.each do |input|
      CONTRACT.exact!(input, %w[reference url narHash attribute], "project input")
      %w[reference url attribute].each { |key| CONTRACT.scalar!(input.fetch(key), "project input #{key}") }
      CONTRACT.digest!(input.fetch("narHash"))
    end
    CONTRACT.unique!(inputs.map { |input| input.fetch("reference") }, "project input reference")
    CONTRACT.reject!("native bindings require declared Nix project inputs") if !resolution.fetch("bindings").empty? && inputs.empty?
    archives = document.fetch("archives")
    CONTRACT.list!(archives, "native archive transport")
    archives.each do |archive|
      CONTRACT.exact!(archive, %w[name version platform sha256 transport], "native archive transport")
      package = resolution.fetch("packages").find { |candidate| candidate.fetch("name") == archive.fetch("name") }
      CONTRACT.reject!("native archive transport differs from selected package") unless package &&
        %w[name version platform].all? { |key| archive.fetch(key) == package.fetch(key) } && archive.fetch("sha256") == package.fetch("archiveHash")
      transport = archive.fetch("transport")
      CONTRACT.reject!("native archive transport is missing") unless transport.is_a?(Hash)
      case transport["kind"]
      when "vendored"
        CONTRACT.exact!(transport, %w[kind path], "vendored native archive")
        CONTRACT.path!(transport.fetch("path"))
      when "url"
        CONTRACT.exact!(transport, %w[kind url], "verified native archive URL")
        CONTRACT.scalar!(transport.fetch("url"), "verified native archive URL")
        url = transport.fetch("url")
        # Share the lexical contract with Nix. The writer must verify actual
        # fetch bytes before recording a URL; fetchers validate URI semantics.
        CONTRACT.reject!("unsupported native replay URL") unless url.ascii_only? && url.match?(%r{\Ahttps?://[^/?#[:space:]]+(/[^#[:space:]]*)?(\?[^#[:space:]]*)?\z})
      when "nix"
        CONTRACT.exact!(transport, %w[kind reference file], "declared Nix native archive")
        CONTRACT.path!(transport.fetch("file"))
        CONTRACT.reject!("native archive refers to an undeclared Nix input") unless inputs.any? { |input| input.fetch("reference") == transport.fetch("reference") }
      else
        CONTRACT.reject!("unsupported native archive transport kind")
      end
    end
    CONTRACT.unique!(archives.map { |archive| archive.fetch("name") }, "native archive transport")
    CONTRACT.reject!("native archive transport closure is incomplete") unless archives.map { |archive| archive.fetch("name") }.sort == resolution.fetch("packages").map { |package| package.fetch("name") }.sort
    resolution.fetch("bindings").each do |binding|
      archive = archives.find { |entry| entry.fetch("name") == binding.fetch("name") }
      CONTRACT.reject!("selected native binding lacks a declared Nix transport") if archive && archive.fetch("transport").fetch("kind") != "nix"
    end
    project_specs!(document.fetch("projectSpecs"), resolution)
    document
  end

  def self.parse(bytes)
    validate!(CONTRACT.parse(bytes))
  end

  def self.build(resolution, archives:, project_inputs: [], project_specs: [])
    document = {"version" => 4, "nativeResolution" => resolution, "archives" => archives,
                "projectInputs" => project_inputs, "projectSpecs" => project_specs,
                "definitionHash" => definition_hash(resolution)}
    document["contentHash"] = CONTRACT.content_hash(document)
    validate!(document)
  end

  def self.dump(document)
    validate!(document)
    JSON.generate(CONTRACT.canonical(document)) + "\n"
  end

  def self.check_project!(document, project)
    validate!(document)
    project = File.realpath(project)
    native_lock = File.join(project, "Gemfile.lock")
    CONTRACT.reject!("ambiguous Gemfile.lock for pre-lockfile SDK") if File.exist?(native_lock) || File.symlink?(native_lock)
    manifests = document.fetch("nativeResolution").fetch("manifests")
    actual = ["Gemfile"] + Dir.glob("**/*.gemspec", base: project).reject { |path| path.start_with?("vendor/") }
      .select { |path| File.file?(File.join(project, path)) || File.symlink?(File.join(project, path)) }
    actual << ".ruby-version" if File.file?(File.join(project, ".ruby-version"))
    CONTRACT.reject!("pre-lockfile project manifest inventory is stale") unless actual.sort == manifests.map { |record| record.fetch("path") }.sort
    manifests.each do |record|
      path = File.realpath(File.join(project, record.fetch("path")))
      CONTRACT.reject!("pre-lockfile project manifest escapes project role") unless path.start_with?(project + "/") && File.file?(path)
      CONTRACT.reject!("pre-lockfile project manifest bytes are stale") unless File.size(path) == record.fetch("size") && CONTRACT.hash_file(path) == record.fetch("sha256")
    end
    document
  end
end
