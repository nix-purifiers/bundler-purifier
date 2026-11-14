# SPDX-License-Identifier: MIT
require "tmpdir"
require "fileutils"
require "rubygems"
require "json"
require "open3"
require_relative "../pkgs/cli/tools/native_bundle"
library = ARGV.shift || "json"
Dir.mktmpdir("bundler-sdk-composition-") do |root|
  project = File.join(root,"producer")
  FileUtils.mkdir_p(project)
  File.write(File.join(project,"Gemfile"), "source 'https://rubygems.org'\ngem '#{library}', '= #{Gem::Specification.find_by_name(library).version}'\n")
  bundle = Gem.bin_path("bundler", "bundle")
  env = {"BUNDLE_GEMFILE"=>File.join(project,"Gemfile")}
  raise "producer lock failed" unless system(env,Gem.ruby,bundle,"lock","--local",chdir:project)
  archives = File.join(root,"archives")
  raise "capture failed" unless system(env,Gem.ruby,bundle,"exec",Gem.ruby,File.expand_path("../pkgs/cli/tools/capture_gems.rb", __dir__),archives,chdir:project)
  spec=File.join(root,"projection.json")
  File.write(spec,JSON.dump({"identity"=>"jsonfixture","archives"=>Dir[File.join(archives,"*.gem")],"intrinsics"=>JSON.parse(File.read(File.join(archives,"intrinsics.json")))}))
  repo=File.join(root,"repository");catalog=File.join(root,"catalog.json")
  raise "projection failed" unless system(Gem.ruby,ENV.fetch("BUNDLER_PURIFIER_RUBYGEMS_TOOL"),spec,repo,catalog)
  consumer=File.join(root,"consumer");FileUtils.mkdir_p(consumer)
  File.write(File.join(consumer,"Gemfile"),"source #{('file://'+repo).inspect}\ngem '#{library}', '>= 99'\n")
  views=[{"repository"=>repo,"catalog"=>catalog}]
  env={"BUNDLE_PATH"=>File.join(consumer,"vendor/bundle")}
  checks = {
    "json" => "require 'json'; raise unless JSON.parse(JSON.dump([42]))==[42]",
    "psych" => "require 'psych'; raise unless Psych.safe_load('42')==42",
    "pathname" => "require 'pathname'; raise unless Pathname.new('a').join('b').to_s=='a/b'",
    "stringio" => "require 'stringio'; raise unless StringIO.new('42').read=='42'",
  }
  [["lock","--full-index"],["install","--full-index"],["exec",Gem.ruby,"-e",checks.fetch(library)+"; puts 'SDK COMPOSITION PASSED'"]].each do |arguments|
    raise "consumer failed" unless PurifierNativeBundle.run(arguments,root:consumer,views:views,ruby:Gem.ruby,bundle:bundle,env:env,persist_lock:arguments.first=="lock")
  end
end
