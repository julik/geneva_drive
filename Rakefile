require "bundler/setup"
require "bundler/gem_tasks"

require "rake/testtask"
require "standard/rake"
require "yard"

YARD::Rake::YardocTask.new("yard")

task doc: [:yard] do
  outfile = "doc/MANUAL.html"
  `bin/md2html MANUAL.md #{outfile}`
  warn "#{outfile} written"
end

APP_RAKEFILE = File.expand_path("test/dummy/Rakefile", __dir__)
load "rails/tasks/engine.rake"
