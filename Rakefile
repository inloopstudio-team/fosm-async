# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("lib", __dir__)

require "bundler/setup"
require "rake"
require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/**/*_test.rb"]
  t.verbose = true
  t.warning = true
end

desc "Run litmus tests only"
task :litmus do
  sh "ruby -Ilib:test test/fosm_async_test.rb -n /Litmus/"
end

desc "Run smoke tests only"
task :smoke do
  sh "ruby -Ilib:test test/fosm_async_test.rb -n /Smoke/"
end

desc "Run all tests with coverage"
task :coverage do
  ENV["COVERAGE"] = "true"
  Rake::Task[:test].invoke
end

task default: :test
