# frozen_string_literal: true

require_relative "lib/version"

Gem::Specification.new do |s|
  s.name = "dependaboat"
  s.version = Dependaboat::VERSION
  s.summary = "Ferry Dependabot alerts to GitHub Issues and Projects"
  s.description = "Create GitHub Issues and GitHub Project Items from Dependabot alerts"
  s.authors = ["CompanyCam"]
  s.email = "jeff.mcfadden@companycam.com"
  s.license = "MIT"
  s.files = Dir.glob("lib/**/*")
  s.homepage = "https://github.com/companycam/dependaboat"
  s.executables = %w[dependaboat]

  s.add_dependency "ghx", "~> 0.2.0"
  s.add_dependency "dotenv", "~> 3.1.2"
  s.add_dependency "faraday", "~> 2.9.0"
  s.add_dependency "faraday-retry", "~> 2.2.1"

  s.add_development_dependency "standardrb"
  s.add_development_dependency "debug"
  s.add_development_dependency "minitest"
end
