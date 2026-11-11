# SPDX-License-Identifier: MIT
require_relative "../tools/native_environment"

contract = PurifierNativeEnvironment
checks = 0
rejects = lambda do |label, &operation|
  begin
    operation.call
  rescue PurifierNativeEnvironment::Invalid
    checks += 1
    next
  end
  raise "accepted invalid #{label}"
end

rejects.call("duplicate top-level key") { contract.parse("{\"a\":1,\"a\":2}\n") }
rejects.call("duplicate nested key") { contract.parse("{\"a\":{\"b\":1,\"b\":2}}\n") }
rejects.call("noncanonical key order") { contract.parse("{\"z\":1,\"a\":2}\n") }
rejects.call("alternate whitespace") { contract.parse("{ \"a\":1}\n") }
rejects.call("document bound") { contract.parse(" " * (contract::MAX_DOCUMENT + 1)) }
value = {"a" => [{"b" => "genuine bytes", "c" => nil}]}
raise "canonical JSON failed round trip" unless contract.parse(JSON.generate(value) + "\n") == value
checks += 1

bytes = "# native SDK environment\n"
snapshot = {"path" => "vendor/gems/environment.rb", "size" => bytes.bytesize,
            "sha256" => contract.hash_bytes(bytes), "base64" => Base64.strict_encode64(bytes)}
contract.snapshot!(snapshot)
checks += 1
rejects.call("changed snapshot bytes") { contract.snapshot!(snapshot.merge("base64" => Base64.strict_encode64(bytes.tr("n", "x")))) }
rejects.call("float size") { contract.snapshot!(snapshot.merge("size" => bytes.bytesize.to_f)) }
rejects.call("negative size") { contract.snapshot!(snapshot.merge("size" => -1)) }
rejects.call("oversized snapshot") { contract.snapshot!(snapshot.merge("size" => contract::MAX_SNAPSHOT + 1)) }
rejects.call("alternate base64 padding bits") { contract.snapshot!({"path" => "x", "size" => 1, "sha256" => contract.hash_bytes("a"), "base64" => "YR=="}) }
rejects.call("unknown snapshot field") { contract.snapshot!(snapshot.merge("execute" => true)) }
["/absolute", "../outside", "a/../b", "a/./b", "a//b", "a/", "a\\b", "a\nfile"].each do |path|
  rejects.call("unsafe relative path #{path.inspect}") { contract.path!(path) }
end
contract.path!("vendor/gems/ruby/1.8/environment.rb")
checks += 1
rejects.call("duplicate record") { contract.unique!(["same", "same"], "test record") }
rejects.call("noncanonical digest padding") { contract.digest!("sha256-" + "A" * 42 + "B=") }
puts "#{checks} native environment contract checks passed"
