Gem::Specification.new do |s|
  s.name = "historical_greeting"
  s.version = "1.0.0"
  s.summary = "Historical runtime and compiled dependency fixture"
  s.authors = ["Fixture"]
  s.license = "MIT"
  s.required_ruby_version = ">= 1.9.0"
  s.files = Dir["lib/**/*.rb", "exe/*"]
  s.bindir = "exe"
  s.executables = ["historical-greeting"]
  s.add_dependency "json", "= 1.1.9"
end
