# SPDX-License-Identifier: MIT
{
  pkgs,
  build,
  producer,
  purifier,
}:
let
  inherit (pkgs) lib;
  ruby = producer.packages.app.ruby;
  repository = producer.projections.rubygems;
  sdkFacts = pkgs.runCommand "ruby-sdk-intrinsic-facts" { nativeBuildInputs = [ ruby ]; } ''
    mkdir -p "$out"
    ruby -rjson -rrbconfig -e '
      spec = Gem::Specification.find_by_name("pathname")
      entry = { "name" => spec.name, "version" => spec.version.to_s,
        "sdk" => RbConfig::CONFIG.fetch("prefix"), "ruby" => RUBY_VERSION,
        "system" => Gem::Platform.local.to_s, "dependencies" => [] }
      File.write(ARGV.fetch(0), JSON.dump([entry]))
    ' "$out/intrinsics.json"
  '';
  sdkProjection = purifier.rubygemsProjections {
    archives = [ ];
    intrinsics = builtins.fromJSON (
      builtins.unsafeDiscardStringContext (builtins.readFile "${sdkFacts}/intrinsics.json")
    );
    producer = sdkFacts;
    inherit ruby;
    inherit (pkgs) runCommand;
  };
  sdkInput = sdkFacts // {
    projections = sdkProjection;
  };
  views = builtins.toJSON [
    {
      repository = toString repository;
      catalog = repository.catalog;
    }
    {
      repository = toString sdkProjection.rubygems;
      catalog = sdkProjection.rubygems.catalog;
    }
  ];
  foreignPlatform = if pkgs.stdenv.hostPlatform.isAarch64 then "x86_64-linux" else "aarch64-linux";
  foreignLock = pkgs.writeText "opposite-platform-Gemfile.lock" ''
    GEM
      remote: file://${repository}/
      specs:
        helper (99.0.0)
        msgpack (99.0.0-${foreignPlatform})
        nokogiri (99.0.0-${foreignPlatform})
        pathname (99.0.0)

    PLATFORMS
      ${foreignPlatform}

    DEPENDENCIES
      helper (>= 99)
      msgpack (>= 99)
      nokogiri (>= 99)
      pathname (>= 99)

    BUNDLED WITH
       2.6.9
  '';
  nativeManifest = pkgs.writeText "composed-Gemfile" ''
    source "file://${repository}"
    gem "helper", ">= 99"
    gem "msgpack", ">= 99"
    gem "nokogiri", ">= 99"
    gem "pathname", ">= 99"
  '';
  recordLock = pkgs.writeText "record-composed-lock.rb" ''
    load ARGV.fetch(0)
    bp = BundlerPurifier
    lock = { "version" => 3, "ruby" => RUBY_VERSION,
             "definitionHash" => bp.definition_hash,
             "bundlerHash" => ENV.fetch("bundlerHash") }
    lock["contentHash"] = bp.content_hash(lock)
    File.open("bundler-purifier.lock.json", "w") { |file| file.puts(JSON.pretty_generate(lock)) }
  '';
  source =
    pkgs.runCommand "bundler-composed-consumer-source"
      {
        nativeBuildInputs = [ ruby ];
        inputViews = views;
        bundlerHash =
          (builtins.fromJSON (builtins.readFile ./fixtures/app/bundler-purifier.lock.json)).bundlerHash;
      }
      ''
        export HOME="$TMPDIR/home"
        mkdir -p "$HOME" "$out"
        cd "$out"
        cp ${nativeManifest} Gemfile
        cp ${foreignLock} Gemfile.lock
        chmod u+w Gemfile Gemfile.lock
        export BUNDLER_PURIFIER_INPUT_VIEWS="$inputViews"
        export BUNDLER_PURIFIER_PERSIST_LOCK=1
        ruby ${../pkgs/cli/tools}/native_bundle_command.rb lock --full-index
        BUNDLE_CACHE_PATH="$TMPDIR/native-cache" ruby ${../pkgs/cli/tools}/native_bundle_command.rb cache --all-platforms --no-install
        ruby ${recordLock} ${../bin/bundler-purifier}
      '';
  consumer = build {
    src = source;
    dependencies = [
      producer.packages.app
      sdkInput
    ];
    checkCommand = ''
      bundle exec ruby -e '
        require "pathname"
        raise unless Pathname.new("a").join("b").to_s == "a/b"
        require "msgpack"
        require "nokogiri"
        raise unless MessagePack.unpack(MessagePack.pack([42])) == [42]
        raise unless Nokogiri::XML("<answer>42</answer>").at("answer").text == "42"
        %w[msgpack nokogiri].each do |name|
          raise "native hooks rerun" unless Gem.loaded_specs.fetch(name).extensions.empty?
        end
      '
    '';
  };
  ordinary =
    pkgs.runCommand "bundler-ordinary-native-consumer"
      {
        nativeBuildInputs = [ ruby ];
        catalog = repository.catalog;
      }
      ''
        export HOME="$TMPDIR/home"
        export BUNDLE_PATH="$TMPDIR/bundle"
        mkdir -p "$HOME"
        ruby -rjson -e '
          catalog = JSON.parse(File.read(ENV.fetch("catalog")))
          lines = ["source \"file://${repository}\""]
          %w[helper msgpack nokogiri].each do |name|
            entry = catalog.fetch("packages").find { |package| package.fetch("name") == name }
            lines << "gem #{name.inspect}, #{("= " + entry.fetch("version")).inspect}"
          end
          File.write("Gemfile", lines.join("\n") + "\n")
        '
        bundle install --full-index
        bundle exec ruby -e '
          require "msgpack"
          require "nokogiri"
          raise unless MessagePack.unpack(MessagePack.pack([42])) == [42]
          raise unless Nokogiri::XML("<answer>42</answer>").at("answer").text == "42"
          raise unless Gem.loaded_specs.fetch("msgpack").extensions.empty?
        '
        touch "$out"
      '';

in
pkgs.runCommand "bundler-native-projection-consumer" { passthru = { inherit sdkInput; }; } ''
  test -d ${consumer.tests}
  test -f ${ordinary}
  # Provided artifacts are absent from download entries, including the
  # native dependencies and the local helper's transitive runtime graph.
  test ${toString (builtins.length consumer.fetches)} -eq 1
  touch "$out"
''
