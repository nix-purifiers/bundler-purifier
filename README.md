# bundler-purifier

bundler-purifier keeps Bundler's development workflow on locked,
Nix-resolved dependencies.

The shared [purifier](https://github.com/nix-purifiers/purifier) library
fetches the downloads. It builds on x86_64-linux, aarch64-linux and
aarch64-darwin.

## Quickstart

From the project root:

```zsh
nix shell 'github:nix-purifiers/bundler-purifier'
bundler-purifier lock
bundler-purifier prefetch
bundle exec rake
```

The package supplies a `bundle` wrapper for locked resolution. Without a
purifier lockfile it warns and runs ordinary, impure Bundler.
`.bundler-purifier/` holds caches and GC roots. Commit `Gemfile.lock` and
`bundler-purifier.lock.json`, and ignore `.bundler-purifier/`.

`prefetch` installs gems into `vendor/bundle` unless a Bundler path is
already configured. Add that directory to `.gitignore`. `bundle exec`
uses this project’s bundle; no RVM gemset is required.

For persistent use, add these packages through your usual Nix configuration.


## Development loop

Day-to-day work goes through Bundler's own commands: `bundle exec`,
`bundle exec rake`, `bundle exec rails server`. After changing the
Gemfile, run `bundler-purifier lock`. The wrapper captures native
`bundle add`, `remove`, `update` and `lock` changes automatically. `bundler-purifier update [<gem>...]` re-resolves
every gem, or the named ones, with `bundle update`, and then locks.

`lock` relocks only when the Gemfile, `Gemfile.lock` or a gemspec changed,
and `lock --force` relocks regardless; a relock of an unchanged project
writes the same lockfile byte for byte. The lock run uses the Ruby the
project asks for, in `.ruby-version` or in the `RUBY VERSION` section of
`Gemfile.lock`, and builds nixpkgs' Ruby of that minor version when it
differs from the Ruby the command runs on. The project's `.bundle/config`
applies to the lock run, except the settings that would narrow what is
locked (groups, path, frozen and deployment). The builds keep the
committed `.bundle/config` too, so settings such as compile flags for a
native extension (`BUNDLE_BUILD__<gem>`) apply in the sandbox.

`bundler-purifier publish` builds the `release` with Nix and pushes each
gem file with `gem push`. Options after `publish` go to `gem push`, and
credentials work as they do for `gem push`.

## Dependencies from Nix projects

Export a producer's `projections.rubygems`, then declare it while locking:

```zsh
bundler-purifier lock \
  --input 'github:your-org/your-library#default'
bundle exec rake
```

Keep the Gemfile's ordinary dependency requirements. The integration binds
supplied gems to their Nix identities; only the producer's Nix source pin
enters the purifier lock. In a Nix build, `dependencies = [ library ];`
declares the same input directly. Packages and releases expose the prepared
runtime graph through `projections.rubygems`, including compiled extensions.
Libraries delivered by Ruby stay with their producing SDK; the integration
selects that SDK automatically. SDK requirements must agree across inputs.

For composed projects, `publish` uploads those namespaced gem archives with
exact dependency versions. Matching published archives are reused; different
bytes at an existing version stop publication. Ordinary Bundler consumers
need no purifier code to use the resulting repository.

## Building the project with Nix

Once the native development workflow is working, you can also build and
test the whole project in the Nix sandbox. For this step, keep a flake or
another Nix build definition in the project's repository, or maintain an
external packaging repository that points at its sources and lockfiles.
The builder consumes the same lockfiles as the development workflow.

`result` is the app with its bundle installed. The flake's
`overlays.default` adds one attribute to a package set, the scope
`bundler-purifier`, which holds the builder `buildBundlerProject` and the
command `cli`.

A project whose authors want a flake can package itself with one. The flake
calls the builder directly, and it can live in the project's repository or
in another one:

```nix
{
  inputs.bundler-purifier.url =
    "github:nix-purifiers/bundler-purifier";
  inputs.nixpkgs.follows = "bundler-purifier/nixpkgs";

  outputs =
    { nixpkgs, bundler-purifier, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        overlays = [
          bundler-purifier.overlays.default
        ];
      };
      project =
        pkgs.bundler-purifier.buildBundlerProject {
        src = ./.;
      };
    in
    {
      packages.${system} = project.packages;
      checks.${system}.tests = project.tests;
      devShells.${system}.default = project.devShell;
    };
}
```

`nix build '.#app'` builds the app, and `nix shell '.#bundle' -c bundle
exec ruby main.rb`, run in the app's store path, runs it. The builder's
result has the attributes of the contract:

- `packages.app`, the project with its bundle installed in deployment mode,
  and `packages.bundle`, the locked Bundler on the app's Gemfile.
- `packages.<gem>`, the gem file that each gemspec of the project builds.
- `tests`, the `app` build with `checkCommand` (`bundle exec rake` by
  default) run after the install.
- `release`, the gem files that `bundler-purifier publish` pushes.
- `fetches`, the download entries of the lock, for every system.

It also has `executables.<name>`, each executable the gemspecs declare, and
`devShell`, a shell with the build's Ruby and libraries.
`lib.bundler-purifier.readLock` reads the lock into the contract's shape
for tools such as SBOM generators.

The builder takes what it needs from the package set by name: `stdenv`,
`mkShell`, `defaultGemConfig`, the Rubies `ruby_3_4` and `ruby_4_0`, and
the packages the shared library's fetchers build with. It takes no
`pkgs`. `bundler-purifier.buildBundlerProject.override` replaces any of
them for one builder, and `bundler-purifier.overrideScope` replaces what
the whole scope holds. `nix/lib/build-bundler-project.nix` documents the
builder's own arguments. A build runs on the Ruby of the minor version the
lock was made with, and `ruby` replaces it, as it must for a version the
builder has no Ruby for. `nativeBuildInputs` and `buildInputs` give native extensions what
they compile and link against, beyond the libraries nixpkgs' gem
configuration names for the locked gems (`useGemConfig`). The libraries
are on `LD_LIBRARY_PATH` in the shell and the `bundle` wrapper, for gems
that open one through FFI, such as ruby-vips. `without` leaves Bundler
groups out of `app`. `fetchers` replaces nixpkgs' `fetchurl` or `fetchgit`,
for a gem server or a git repository that needs credentials, or a mirror.
`externalPaths` gives the trees of path sources outside the project.

### An external build

A project can instead keep its build outside its repository. The flake
that calls the builder keeps the purifier lockfile and passes it as
`lockFile`. It can also keep its own copy of `Gemfile.lock` and pass it as
`gemfileLock`, which the build then uses in place of the copy in `src`.
That suits a project whose committed `Gemfile.lock` is missing, out of
date or written by another version of Bundler, and which the flake builds
from its source as published.

```nix
bundler-purifier.buildBundlerProject {
  src = project;
  lockFile = ./bundler-purifier.lock.json;
  gemfileLock = ./Gemfile.lock;
}
```

`readLock` takes the same `lockFile` and `gemfileLock`. The commands take
`--lockfile <path>` or `BUNDLER_PURIFIER_LOCKFILE` for the purifier
lockfile, and `--tool-lockfile <path>` or
`BUNDLER_PURIFIER_TOOL_LOCKFILE` for `Gemfile.lock`. With the second,
`lock` and `update` write `Gemfile.lock` at that path and leave the copy in
the tree as it is. `lock` starts from the copy in the tree when the file at
that path does not exist yet. The dev shell of the flake that calls the
builder can set both variables, so a developer in that shell runs the
commands with no flag.

### One-off builds without a project Nix file

For an ad hoc build, the builder can also be evaluated directly from the
project root. Replace the example package name with one from your project:

```zsh
nix build --impure --expr 'let
  purifier = builtins.getFlake "github:nix-purifiers/bundler-purifier";
  pkgs = import purifier.inputs.nixpkgs {
    system = builtins.currentSystem;
    overlays = [ purifier.overlays.default ];
  };
in
(pkgs.bundler-purifier.buildBundlerProject { src = ./.; })
.packages.app'
```

This uses the purifier's pinned nixpkgs, matching the lock command above.
To build with ambient `<nixpkgs>` from your Nix search path instead,
replace `import purifier.inputs.nixpkgs` with `import <nixpkgs>`.
Both forms need no Nix files in your project. The build tool and language
versions must match the lockfile; with ambient nixpkgs, lock with the
purifier from that package set or pass a compatible toolchain to the builder.

## Working offline

```zsh
nix shell 'github:nix-purifiers/bundler-purifier'
bundler-purifier prefetch
```

`prefetch` realizes everything the lock lists for the current system: the
gem files and git checkouts, as Bundler's gem cache, and the dev shell
with the project's Ruby and libraries. Both stay alive through GC roots in
`.bundler-purifier/` beside the purifier lockfile, which belongs in
`.gitignore`. It names that gem cache as Bundler's `cache_path` in the
project's `.bundle/config`, and runs `bundle install --local` in the shell;
arguments after `prefetch` go to `bundle install`. Afterwards
`bundle install`, `bundle exec` and the language server work in that shell
with the network cut off.

## Editor

Ruby LSP works offline when the project locks it like any other gem:

```ruby
group :development do
  gem "ruby-lsp", require: false
end
```

Then run `bundler-purifier lock` and `bundler-purifier prefetch`, and start
the editor from the `nix shell` environment. Run the language server
through `bundle exec ruby-lsp`. Ruby LSP uses the project's bundle when the
Gemfile has it, and needs no download of its own.

## Troubleshooting

Each of these fails, in the commands and when Nix evaluates the build,
with a message that names the fix:

- **The Gemfile, `Gemfile.lock` or a gemspec changed since the lock was
  made**, as after `bundle add`: run `bundler-purifier lock`.
- **The purifier lockfile lacks an entry `Gemfile.lock` needs**, such as
  the hash of a new git checkout: run `bundler-purifier lock`.
- **The purifier lockfile was edited by hand**, its content no longer
  matching its `contentHash`: run `bundler-purifier lock --force`.
- **The purifier lockfile is cut short, overwritten or of an older
  format**: run `bundler-purifier lock --force`.
- **A path source outside the project has no tree**: pass it as
  `externalPaths`.

## Supported language repositories

bundler-purifier fetches gems from each kind of source a `Gemfile.lock`
names:

- **Gem servers** (`source "https://…"`): each gem file, for every platform
  in `Gemfile.lock`, with the platform gems a system cannot install left
  out of that system's downloads. When Bundler is configured with a mirror
  for the source (`bundle config mirror.https://rubygems.org <mirror>`),
  the lock records the mirror's URL as a fallback. A gem in an old
  `Gemfile.lock` section with several remotes is locked at the remote that
  serves the file.
- **Git** (`git:`, `github:`), with `submodules: true` too. The Nix sandbox
  has no SSH keys, so a source over SSH (`git@host:owner/repo` or
  `ssh://host/owner/repo`) is fetched from the HTTPS URL of the same host
  and path; a private repository takes a credentialed `fetchers.fetchgit`.
  The lock run itself uses your SSH keys and git credential helpers.
- **Paths inside the project** (`path:`, `gemspec`). Their gemspecs build
  `packages.<gem>`. Gemspecs that list their files with `git ls-files`
  work, since the builds put the source in a fresh git repository.
- **Paths outside the project**, such as `path: "../shared"`, through
  `externalPaths`. The build lays the project and those trees out at the
  same relative positions, and `packages.app.projectDir` is the project's
  directory in the app.

Two kinds of source cannot build in the Nix sandbox:

- **Path sources given by absolute path.** Bundler writes such a path into
  `Gemfile.lock` unchanged. A Nix build can create files only inside its
  own build directory, so it cannot put a tree at an absolute path, and
  `lock` fails with that explanation. Paths relative to the Gemfile work.
- **Bundler plugin sources** (`source "…", type: "…"`). A plugin source
  fetches through the plugin's own Ruby code: there is no URL and no
  checkout to record, only whatever files the plugin writes. A Nix build
  would have to run that code with the network, which the sandbox forbids.

Native extensions need their system libraries, which `Gemfile.lock` does
not name: nixpkgs' gem configuration supplies the common ones, and the
builder takes the rest. Bundler evaluates the gemspec of every path source
each time `bundle exec` starts; in the installed app a gemspec that calls
`git ls-files` runs outside a repository, so git prints "not a git
repository" to stderr, and the app runs normally.

## Examples

For day-to-day work on these projects, use the native-tool setup and
commands in [Quickstart](#quickstart) and [Development loop](#development-loop).
The Nix expressions below show optional sandboxed packaging of those
projects.

### A Rails app: Lobsters

[Lobsters](https://github.com/lobsters/lobsters), the Rails app behind
lobste.rs, asks for its own Ruby in `.ruby-version` and keeps compile flags
for sqlite3 in its `.bundle/config`. bundler-purifier takes both as they
are. In a checkout of Lobsters:

```zsh
nix shell 'github:nix-purifiers/bundler-purifier'
bundler-purifier lock
```

The lock run builds nixpkgs' Ruby of the version Lobsters asks for.
Lobsters' `Gemfile.lock` has a `CHECKSUMS` section, so
`bundler-purifier.lock.json` holds only a few fields. Lobsters' image
processing loads libvips through FFI, so the build passes libvips in
`buildInputs`. From the same directory:

```zsh
nix build --impure --expr 'let
  purifier = builtins.getFlake "github:nix-purifiers/bundler-purifier";
  pkgs = import purifier.inputs.nixpkgs {
    system = builtins.currentSystem;
    overlays = [ purifier.overlays.default ];
  };
in
(pkgs.bundler-purifier.buildBundlerProject {
  src = ./.;
  name = "lobsters";
  buildInputs = [ pkgs.vips ];
}).packages.app'
```

`result` is Lobsters with its bundle installed. For day-to-day work on
Lobsters:

```zsh
nix shell 'github:nix-purifiers/bundler-purifier'
bundler-purifier prefetch
cp config/database.yml.sample config/database.yml
RAILS_ENV=test bundle exec rails db:create db:schema:load
bundle exec rspec
```

To keep `bundler-purifier.lock.json` out of the Lobsters checkout, write
it elsewhere with `bundler-purifier --lockfile <path> lock` and pass the
same path to the builder as `lockFile`.

## Credits

The purifier idea was inspired by nixcloud's
[cargo (libnix)](https://github.com/nixcloud/cargo).

## License

MIT
