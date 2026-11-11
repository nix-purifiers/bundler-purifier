require_relative "lib/greeting/version"

Gem::Specification.new do |spec|
  spec.name = "greeting"
  spec.version = Greeting::VERSION
  spec.summary = "A gem the bundler-purifier tests build"
  spec.authors = ["bundler-purifier"]
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1"
  # The usual way of listing a gem's files, which the Nix build supports
  # by putting the source in a git repository.
  spec.files = `git ls-files -z`.split("\x0").select { |f| f.start_with?("lib/", "exe/") }
  spec.bindir = "exe"
  spec.executables = ["greet"]
  spec.add_dependency "json", "= 2.18.0"
  spec.add_dependency "rainbow", "~> 3.1"
end
