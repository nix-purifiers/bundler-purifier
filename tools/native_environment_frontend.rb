# SPDX-License-Identifier: MIT
require "tmpdir"
require "tempfile"
require_relative "native_environment_prepare"
require_relative "native_environment_lock"
require_relative "native_bundle"

class PurifierNativeEnvironmentFrontend
  C = PurifierNativeEnvironment
  S = PurifierNativeEnvironmentSDK
  L = PurifierNativeEnvironmentLock
  P = PurifierNativeEnvironmentPrepare

  def initialize(context)
    @context = context
    @root = File.realpath(context.root)
    @lockfile = context.lockfile_path
  end

  def run(command, arguments)
    case command
    when "lock" then capture(force: !!arguments.delete("--force"))
    when "update"
      C.reject!("pre-lockfile cached updates do not accept individual gem names") unless arguments.empty?
      capture(force: true, refresh: true)
    when "prefetch"
      C.reject!("pre-lockfile prefetch does not accept install flags") unless arguments.empty?
      prefetch
    when "shell" then shell(arguments)
    when "publish" then publish(arguments)
    else C.reject!("unsupported pre-lockfile command")
    end
  rescue C::Invalid => error
    @context.fail!(error.message)
  end

  # Validate each ancestor before creating a project-owned directory. In
  # particular, mkdir_p must never follow a vendor/state symlink outside it.
  def owned_directory(path, mode:, create: true)
    expanded = File.expand_path(path)
    anchor = @root
    unless expanded.start_with?(@root + "/")
      state = File.expand_path(@context.state_dir)
      C.reject!("native directory escapes project role") unless expanded == state || expanded.start_with?(state + "/")
      anchor = File.realpath(File.dirname(@lockfile))
      expanded = File.join(anchor, ".bundler-purifier") + expanded.delete_prefix(state)
    end
    relative = expanded.delete_prefix(anchor + "/")
    current = anchor
    relative.split("/").each do |part|
      current = File.join(current, part)
      if File.exist?(current) || File.symlink?(current)
        C.reject!("native directory is not an owned directory") if File.symlink?(current) || !File.directory?(current)
      elsif create
        Dir.mkdir(current, mode)
      end
    end
    expanded
  end

  def inputs(refresh: false)
    owned_directory(@context.state_dir, mode: 0700)
    owned_directory(File.join(@context.state_dir, "inputs"), mode: 0700)
    @context.resolve_project_inputs(refresh: refresh)
    @inputs = @context.instance_variable_get(:@project_inputs)
    @views = @context.instance_variable_get(:@input_views)
    @sdk = File.realpath(File.dirname(@context.lock_ruby_bindir))
    @identity = S.attest(@sdk)
  end

  def read
    document = L.parse(File.binread(@lockfile, C::MAX_DOCUMENT + 1))
    L.check_project!(document, @root)
    inputs
    C.reject!("pre-lockfile SDK differs from capture") unless S.normalized_identity(@identity) == S.normalized_identity(document.fetch("nativeResolution").fetch("sdk"))
    C.reject!("pre-lockfile project inputs differ from capture") unless @inputs == document.fetch("projectInputs")
    document
  end

  def atomic_write(path, bytes)
    FileUtils.mkdir_p(File.dirname(path), mode: 0700)
    Tempfile.create([".native-state-", ".tmp"], File.dirname(path)) do |file|
      file.binmode
      file.write(bytes)
      file.flush
      file.fsync
      File.rename(file.path, path)
    end
  end

  def capture(force:, refresh: false)
    native_lock = File.join(@root, "Gemfile.lock")
    C.reject!("ambiguous Gemfile.lock for pre-lockfile SDK") if File.exist?(native_lock) || File.symlink?(native_lock)
    C.reject!("pre-lockfile profiles do not write --tool-lockfile") if @context.instance_variable_get(:@tool_lockfile_option) || ENV["BUNDLER_PURIFIER_TOOL_LOCKFILE"]
    if !force && File.file?(@lockfile)
      read
      puts "bundler-purifier: pre-lockfile lock is up to date"
      return
    end
    inputs(refresh: refresh)
    provided = PurifierNativeBundle.packages_from_views(@views)
    bindings = provided.keys.sort.map { |name| {"name" => name, "version" => provided.fetch(name).fetch("version")} }
    available = []
    declared = []
    @views.each_with_index do |view, index|
      catalog = JSON.parse(File.binread(view.fetch("catalog")))
      catalog.fetch("packages").each do |entry|
        file = File.join(view.fetch("repository"), entry.fetch("archive"))
        sha256 = C.hash_file(file)
        available << {"path" => file, "sha256" => sha256}
        declared << entry.merge("sha256" => sha256, "reference" => @inputs.fetch(index).fetch("reference"))
      end
    end
    cache = P.legacy?(@identity) ? "vendor/gems/cache" : "vendor/gems/ruby/#{@identity.fetch('abi')}/cache"
    ["vendor/cache", cache].each do |relative|
      Dir.glob(File.join(@root, relative, "*.gem")).sort.each do |path|
        real = File.realpath(path)
        C.reject!("native cache escapes project role") unless real.start_with?(@root + "/") && File.file?(real)
        available << {"path" => real, "sha256" => C.hash_file(real)}
      end
    end
    specifications = Dir.glob("**/*.gemspec", base: @root).reject { |path| path.start_with?("vendor/") }
    manifests = specifications.dup
    manifests << ".ruby-version" if File.file?(File.join(@root, ".ruby-version"))
    owned_directory(@context.state_dir, mode: 0700)
    Dir.mktmpdir("native-capture-", @context.state_dir) do |arena|
      workspace = File.join(arena, "project")
      resolution = P.resolve(@root, @sdk, available, workspace, bindings: bindings, project_gemspecs: manifests)
      specs = P.project_specs(@root, workspace, @sdk, specifications, bindings: bindings)
      archive_records = resolution.fetch("packages").map do |package|
        input = declared.find do |entry|
          %w[name version platform].all? { |key| entry.fetch(key) == package.fetch(key) } && entry.fetch("sha256") == package.fetch("archiveHash")
        end
        transport = if input
          {"kind" => "nix", "reference" => input.fetch("reference"), "file" => input.fetch("archive")}
        else
          filename = File.basename(package.fetch("installedPath")) + ".gem"
          specification = File.join(workspace, package.fetch("specificationPath"))
          source = if P.legacy?(@identity)
            available.find { |entry| entry.fetch("sha256") == package.fetch("archiveHash") }.fetch("path")
          else
            File.join(File.dirname(File.dirname(specification)), "cache", filename)
          end
          relative = File.join("vendor/cache", filename)
          vendor(source, relative, package.fetch("archiveHash"))
          {"kind" => "vendored", "path" => relative}
        end
        {"name" => package.fetch("name"), "version" => package.fetch("version"), "platform" => package.fetch("platform"),
         "sha256" => package.fetch("archiveHash"), "transport" => transport}
      end
      document = L.build(resolution, archives: archive_records, project_inputs: @inputs, project_specs: specs)
      atomic_write(@lockfile, L.dump(document))
    end
    puts "bundler-purifier: wrote #{@lockfile}"
  end

  def vendor(source, relative, expected_hash)
    C.reject!("native selected cache bytes changed during capture") unless C.hash_file(source) == expected_hash
    directory = File.join(@root, File.dirname(relative))
    owned_directory(directory, mode: 0755)
    destination = File.join(@root, relative)
    if File.exist?(destination) || File.symlink?(destination)
      C.reject!("native vendor destination conflicts with captured bytes") unless File.file?(destination) && !File.symlink?(destination) && C.hash_file(destination) == expected_hash
      return
    end
    Tempfile.create([".native-archive-", ".gem"], directory) do |file|
      file.binmode
      File.open(source, "rb") { |input| IO.copy_stream(input, file) }
      file.flush
      C.reject!("native vendor copy changed bytes") unless C.hash_file(file.path) == expected_hash
      File.link(file.path, destination)
    end
  end

  def realize_args
    args = @context.realize_args
    index = args.index("rubyExpression")
    if index && args.fetch(index + 1).empty?
      args[index + 1] = "builtins.storePath #{JSON.generate(@sdk)}"
    end
    index_expression = ENV.fetch("BUNDLER_PURIFIER_LEGACY_INDEX_RUBY_EXPRESSION", "")
    args += ["--argstr", "legacyIndexRubyExpression", index_expression] unless index_expression.empty?
    args
  end

  def expected_app
    JSON.parse(S.run("nix-instantiate", File.join(@context.lib_dir, "realize.nix"), "-A", "packages.app.outPath",
                     *realize_args, "--eval", "--strict", "--json", "--read-write-mode", cwd: @root,
                     deadline_seconds: 3600, stream_stderr: true))
  end

  def receipt_path
    File.join(@context.state_dir, "native-replay.json")
  end

  def prefetch
    document = read
    owned_directory(@context.state_dir, mode: 0700)
    app = S.run("nix-build", File.join(@context.lib_dir, "realize.nix"), "-A", "packages.app", *realize_args,
                "--out-link", File.join(@context.state_dir, "native-app"), cwd: @root,
                deadline_seconds: 3600, stream_stderr: true).strip
    C.reject!("native prefetch output differs from expected build") unless app == expected_app
    working = File.join(app, "native-resolution.json")
    fresh = C.parse(File.binread(working, C::MAX_DOCUMENT + 1))
    C.compare_observation!(document.fetch("nativeResolution"), fresh)
    receipt = {"version" => 1, "lockContentHash" => document.fetch("contentHash"), "project" => @root,
               "sdkHash" => C.hash_bytes(JSON.generate(S.normalized_identity(@identity))), "app" => app,
               "appNar" => S.run("nix", "hash", "path", app).strip, "workingHash" => C.hash_file(working)}
    receipt["contentHash"] = C.content_hash(receipt)
    atomic_write(receipt_path, JSON.generate(C.canonical(receipt)) + "\n")
    puts "bundler-purifier: prefetched native environment"
  end

  def shell(arguments)
    arguments = arguments.drop(1) if arguments.first == "--"
    document = read
    C.reject!("native working state is missing; run bundler-purifier prefetch") unless File.file?(receipt_path)
    receipt = C.parse(File.binread(receipt_path, 65537))
    C.exact!(receipt, %w[version lockContentHash project sdkHash app appNar workingHash contentHash], "native replay receipt")
    C.reject!("native replay receipt is stale; run bundler-purifier prefetch") unless receipt.fetch("version").is_a?(Integer) && receipt.fetch("version") == 1 &&
      receipt.fetch("contentHash") == C.content_hash(receipt) && receipt.fetch("project") == @root &&
      receipt.fetch("lockContentHash") == document.fetch("contentHash") &&
      receipt.fetch("sdkHash") == C.hash_bytes(JSON.generate(S.normalized_identity(@identity))) &&
      receipt.fetch("app") == expected_app && File.directory?(receipt.fetch("app"))
    app = receipt.fetch("app")
    C.reject!("native working files changed; run bundler-purifier prefetch") unless receipt.fetch("appNar") == S.run("nix", "hash", "path", app).strip &&
      receipt.fetch("workingHash") == C.hash_file(File.join(app, "native-resolution.json"))
    command = arguments.empty? ? [ENV.fetch("SHELL", "bash")] : arguments
    exec(S.clean_environment, File.join(@sdk, "bin/ruby"), File.join(__dir__, "native_environment_exec.rb"),
         File.join(app, "project"), @sdk, "--", *command, chdir: @root)
  end

  def publish(arguments)
    read
    options = arguments.dup
    selected_publisher = @context.take_option(options, "--publisher-sdk")
    publisher_sdk = selected_publisher ? File.realpath(selected_publisher) : @sdk
    publisher_identity = selected_publisher ? S.attest(publisher_sdk) : @identity
    publisher = File.join(publisher_sdk, "bin/gem-publish")
    C.reject!("native SDK has no identity-bound publisher launcher; select an attested publisher with --publisher-sdk") unless File.executable?(publisher) &&
      publisher_identity.fetch("components").any? { |component| component.fetch("name") == "gemcutter" && component.fetch("version") == "0.3.0" }
    # The original Gemcutter guard requires Gem135. This is a separate actual
    # SDK context; it never changes the project's Gem101 consumer identity.
    C.reject!("unsupported native publisher interface") unless publisher_identity.fetch("rubygemsReport") == {"name" => "Gem::VERSION", "value" => "1.3.5"}
    output = S.run("nix-build", File.join(@context.lib_dir, "realize.nix"), "-A", "release.projections.rubygems", *realize_args,
                   "--no-out-link", cwd: @root, deadline_seconds: 3600, stream_stderr: true).strip
    files = Dir.glob(File.join(output, "gems/*.gem")).sort
    C.reject!("native release has no projected archives") if files.empty?
    explicit_host = @context.take_option(options, "--host")
    environment = S.clean_environment
    environment["GEMCUTTER_URL"] = explicit_host if explicit_host
    descriptor = JSON.parse(File.binread(File.join(publisher_sdk, "share/bundler-purifier/sdk-components.json")))
    component = descriptor.fetch("components").find { |entry| entry.fetch("name") == "gemcutter" }
    publisher_home = File.dirname(File.dirname(component.fetch("library")))
    host = S.run(File.join(publisher_sdk, "bin/ruby"), "-e",
                 'require "rubygems/command_manager";puts Gem::CommandManager.instance["push"].gemcutter_url',
                 env: environment.merge("GEM_PATH" => publisher_home)).strip
    publication = {"version" => 1, "complete" => false,
      "consumerSdkHash" => C.hash_bytes(JSON.generate(S.normalized_identity(@identity))),
      "publisherSDK" => publisher_identity, "repository" => output,
      "archives" => files.map { |file| {"file" => File.basename(file), "sha256" => C.hash_file(file)} }}
    files.each do |file|
      fetcher = Gem::RemoteFetcher.fetcher
      url = host.delete_suffix("/") + "/gems/" + File.basename(file)
      response = fetcher.request(Gem::Uri.new(url), Gem::Net::HTTP::Get) do |request|
        fetcher.headers.each { |key, value| request.add_field(key, value) }
      end
      unless response.is_a?(Gem::Net::HTTPNotFound)
        bytes = response.is_a?(Gem::Net::HTTPOK) ? response.body : fetcher.fetch_path(url)
        C.reject!("published native archive has different bytes: #{File.basename(file)}") unless C.hash_bytes(bytes) == C.hash_file(file)
        next
      end
      S.run(publisher, "push", file, *options, env: environment, cwd: @root, stream_stderr: true)
    end
    publication["complete"] = true
    publication["contentHash"] = C.content_hash(publication)
    owned_directory(@context.state_dir, mode: 0700)
    atomic_write(File.join(@context.state_dir, "native-publication.json"), JSON.generate(C.canonical(publication)) + "\n")
  end
end
