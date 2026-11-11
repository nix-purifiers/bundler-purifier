# SPDX-License-Identifier: MIT
require "json"
require_relative "native_environment"

module PurifierNativeEnvironmentSDK
  # Deadline covers direct-child exit AND output EOF. Own the process group so
  # an inherited pipe cannot keep a finished SDK probe alive indefinitely.
  def self.run(*argv, env: {}, cwd: nil, deadline_seconds: 90, output_limit: 8 * 1024 * 1024)
    readers = []
    writers = []
    output = [String.new(encoding: Encoding::BINARY), String.new(encoding: Encoding::BINARY)]
    2.times do
      reader, writer = IO.pipe
      readers << reader
      writers << writer
    end
    options = {in: File::NULL, out: writers[0], err: writers[1], pgroup: true}
    options[:chdir] = cwd if cwd
    pid = Process.spawn(env, *argv, **options)
    writers.each(&:close)
    pending = readers.dup
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + deadline_seconds
    status = nil
    until status && pending.empty?
      remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      raise PurifierNativeEnvironment::Invalid, "SDK command deadline exceeded" if remaining <= 0
      status = Process.waitpid2(pid, Process::WNOHANG)&.last unless status
      ready = IO.select(pending, nil, nil, [remaining, 0.05].min)&.first || []
      ready.each do |reader|
        begin
          output[readers.index(reader)] << reader.read_nonblock(65536)
          raise PurifierNativeEnvironment::Invalid, "SDK command output exceeds bound" if output.sum(&:bytesize) > output_limit
        rescue EOFError
          pending.delete(reader)
          reader.close
        rescue IO::WaitReadable
          next
        end
      end
    end
    raise PurifierNativeEnvironment::Invalid, "SDK command failed: #{output[1]}" unless status.success?
    output[0]
  ensure
    if pid
      begin
        Process.kill("KILL", -pid)
      rescue Errno::ESRCH
        nil
      end
      begin
        Process.waitpid(pid) unless status
      rescue Errno::ECHILD
        nil
      end
    end
    (readers + writers).each { |io| io.close unless io.closed? }
  end

  def self.attest(sdk, closure_paths: nil)
    contract = PurifierNativeEnvironment
    sdk = File.realpath(sdk)
    contract.reject!("native SDK must be an immutable Nix output") unless sdk.match?(%r{\A/nix/store/[a-z0-9]{32}-[^/]+\z})
    descriptor_path = File.join(sdk, "share/bundler-purifier/sdk-components.json")
    bytes = File.binread(descriptor_path, 65537)
    contract.reject!("SDK component descriptor exceeds bound") if bytes.bytesize > 65536
    descriptor = JSON.parse(bytes, object_class: contract::UniqueObject, max_nesting: 16)
    contract.exact!(descriptor, %w[schemaVersion components], "SDK component descriptor")
    contract.reject!("unsupported SDK component descriptor") unless descriptor.fetch("schemaVersion").is_a?(Integer) && descriptor.fetch("schemaVersion") == 1
    components = descriptor.fetch("components")
    contract.list!(components, "SDK descriptor component")
    contract.reject!("unsupported native SDK components") unless components.map { |entry| entry.fetch("name") }.sort == %w[bundler json ruby rubygems]
    probe = File.join(__dir__, "native_environment_sdk_probe.rb")
    observation = JSON.parse(run(File.join(sdk, "bin/ruby"), probe,
                                env: {"RUBYOPT" => nil, "RUBYLIB" => nil, "GEM_HOME" => nil, "GEM_PATH" => nil}))
    # Nix builders supply closureInfo's authoritative store-paths file. That
    # mode hashes every physical path without needing a daemon/store database.
    closure = if closure_paths
      contract.reject!("invalid SDK closure input") unless closure_paths.is_a?(Array) && closure_paths.size <= contract::MAX_RECORDS && closure_paths.include?(sdk) && closure_paths.uniq == closure_paths
      closure_paths.to_h do |path|
        contract.reject!("invalid SDK runtime path") unless path.is_a?(String) && path.match?(%r{\A/nix/store/[a-z0-9]{32}-[^/]+\z})
        [path, {"narHash" => run("nix", "hash", "path", "--type", "sha256", path).strip}]
      end
    else
      JSON.parse(run("nix", "path-info", "--json", "--recursive", sdk))
    end
    contract.reject!("SDK closure exceeds bound") unless closure.is_a?(Hash) && closure.size <= contract::MAX_RECORDS
    closure_rows = closure.keys.sort.map { |path| {"path" => path, "narHash" => closure.fetch(path).fetch("narHash")} }
    in_closure = lambda do |path|
      closure.key?(path) || closure.keys.any? { |root| path.start_with?(root + "/") }
    end
    identity_components = components.map do |component|
      contract.exact!(component, %w[name version archive library], "SDK descriptor component")
      native = observation.fetch("components").find { |entry| entry.fetch("name") == component.fetch("name") }
      library = File.realpath(component.fetch("library"))
      archive = File.realpath(component.fetch("archive"))
      contract.reject!("SDK component differs from native observation") unless native && native.fetch("version") == component.fetch("version") && native.fetch("library") == library
      contract.reject!("SDK component escapes bound runtime closure") unless in_closure.call(library) && in_closure.call(archive)
      contract.reject!("SDK artifact is not a regular archive") unless File.file?(archive)
      {"name" => component.fetch("name"), "version" => native.fetch("version"),
       "archiveHash" => contract.hash_file(archive),
       "libraryHash" => run("nix", "hash", "path", "--type", "sha256", library).strip}
    end.sort_by { |component| component.fetch("name") }
    contract.reject!("native interpreter escapes SDK closure") unless in_closure.call(observation.fetch("executable"))
    result = observation.reject { |key, _| %w[components executable].include?(key) }.merge(
      "components" => identity_components,
      "clientArtifact" => identity_components.find { |component| component.fetch("name") == "bundler" },
      "closure" => closure_rows)
    contract.sdk!(result)
    result
  end
end

if __FILE__ == $0
  raise "usage: native_environment_sdk.rb SDK" unless ARGV.size == 1
  puts JSON.generate(PurifierNativeEnvironment.canonical(PurifierNativeEnvironmentSDK.attest(ARGV.fetch(0))))
end
