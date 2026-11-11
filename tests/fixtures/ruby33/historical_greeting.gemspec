Gem::Specification.new do |s|
  s.name = "historical_greeting"
  s.version = "1.0.0"
  s.summary = "Historical runtime and compiled dependency fixture"
  s.authors = ["Fixture"]
  s.license = "MIT"
  s.required_ruby_version = ">= 3.3.8"
  s.files = Dir["lib/**/*.rb", "exe/*"]
  s.bindir = "exe"
  s.executables = ["historical-greeting"]
  s.add_dependency "json", "= 2.9.1"
end
