# frozen_string_literal: true

require_relative "lib/geneva_drive/version"

Gem::Specification.new do |spec|
  spec.name = "geneva_drive"
  spec.version = GenevaDrive::VERSION
  spec.authors = ["Julik Tarkhanov"]
  spec.email = ["me@julik.nl"]
  spec.homepage = "https://github.com/julik/geneva_drive"
  spec.summary = "Durable workflows for Rails applications"
  spec.description = "GenevaDrive provides a clean DSL for defining multi-step workflows that execute asynchronously, with strong guarantees around idempotency, concurrency control, and state management."
  spec.licenses = ["LGPLv3", "Commercial"]

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"

  spec.required_ruby_version = ">= 3.0.0"

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    Dir["{app,config,db,lib,test,config,bin}/**/*", "LICENSE-LGPL.txt", "LICENSE-COMMERCIAL.txt", "Rakefile", "README.md", "MANUAL.md", "CHANGELOG.md"]
  end

  # We only need these specific Rails components - not the full rails gem
  spec.add_dependency "activerecord", ">= 7.2.2"
  spec.add_dependency "activejob", ">= 7.2.2"
  spec.add_dependency "activesupport", ">= 7.2.2"
  spec.add_dependency "railties", ">= 7.2.2"
end
