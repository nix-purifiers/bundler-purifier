Gem::Specification.new do |s|
  s.name = "historical_greeting"
  s.version = "1.0.0"
  s.summary = "Ruby 1.8.3 native dependency fixture"
  s.authors = ["Fixture"]
  s.required_ruby_version = ">= 1.8.3"
  s.files = Dir["lib/**/*.rb"] + Dir["bin/*"]
  s.bindir = "bin"
  s.executables = ["historical-greeting"]
  s.add_dependency "json", "= 1.1.3"
end
