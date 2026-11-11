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

  def inputs(refresh: false)
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
    ["vendor/cache", "vendor/gems/ruby/#{@identity.fetch('abi')}/cache"].each do |relative|
      Dir.glob(File.join(@root, relative, "*.gem")).sort.each do |path|
        real = File.realpath(path)
        C.reject!("native cache escapes project role") unless real.start_with?(@root + "/") && File.file?(real)
        available << {"path" => real, "sha256" => C.hash_file(real)}
      end
    end
    specifications = Dir.glob("**/*.gemspec", base: @root).reject { |path| path.start_with?("vendor/") }
    manifests = specifications.dup
    manifests << ".ruby-version" if File.file?(File.join(@root, ".ruby-version"))
    FileUtils.mkdir_p(@context.state_dir, mode: 0700)
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
          source = File.join(File.dirname(File.dirname(specification)), "cache", filename)
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
    FileUtils.mkdir_p(directory, mode: 0755)
    C.reject!("native vendor directory escapes project role") unless File.realpath(directory).start_with?(@root + "/")
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
    FileUtils.mkdir_p(@context.state_dir, mode: 0700)
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
    C.reject!("native replay receipt is stale; run bundler-purifier prefetch") unless receipt.fetch("version") == 1 &&
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
    publisher = File.join(@sdk, "bin/gem-publish")
    C.reject!("native SDK has no identity-bound publisher launcher") unless File.executable?(publisher) &&
      @identity.fetch("components").any? { |component| component.fetch("name") == "gemcutter" && component.fetch("version") == "0.3.0" }
    output = S.run("nix-build", File.join(@context.lib_dir, "realize.nix"), "-A", "release.projections.rubygems", *realize_args,
                   "--no-out-link", cwd: @root, deadline_seconds: 3600, stream_stderr: true).strip
    files = Dir.glob(File.join(output, "gems/*.gem")).sort
    C.reject!("native release has no projected archives") if files.empty?
    options = arguments.dup
    explicit_host = @context.take_option(options, "--host")
    environment = S.clean_environment
    environment["GEMCUTTER_URL"] = explicit_host if explicit_host
    descriptor = JSON.parse(File.binread(File.join(@sdk, "share/bundler-purifier/sdk-components.json")))
    component = descriptor.fetch("components").find { |entry| entry.fetch("name") == "gemcutter" }
    publisher_home = File.dirname(File.dirname(component.fetch("library")))
    host = S.run(File.join(@sdk, "bin/ruby"), "-e",
                 'require "rubygems/command_manager";puts Gem::CommandManager.instance["push"].gemcutter_url',
                 env: environment.merge("GEM_PATH" => publisher_home)).strip
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
  end
end
