# frozen_string_literal: true

require_relative "lib/gienah/version"

Gem::Specification.new do |spec|
  spec.name = "gienah"
  spec.version = Gienah::VERSION
  spec.authors = ["ydah"]
  spec.email = ["t.yudai92@gmail.com"]

  spec.summary = "Out-of-process Ruby plugin host"
  spec.description = "Content-Length RPC, capability gates, lifecycle management, and a small plugin SDK."
  spec.homepage = "https://github.com/noxdea/gienah"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1.0"
  spec.metadata = {
    "allowed_push_host" => "https://rubygems.org",
    "source_code_uri" => spec.homepage,
    "changelog_uri" => "#{spec.homepage}/blob/main/CHANGELOG.md",
    "rubygems_mfa_required" => "true"
  }

  # Uncomment the line below to require MFA for gem pushes.
  # This helps protect your gem from supply chain attacks by ensuring
  # no one can publish a new version without multi-factor authentication.
  # See: https://guides.rubygems.org/mfa-requirement-opt-in/
  # spec.metadata["rubygems_mfa_required"] = "true"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ Gemfile .gitignore .rspec spec/ .github/])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "saiph", "~> 0.1.0"

  # For more information and examples about making a new gem, check out our
  # guide at: https://guides.rubygems.org/make-your-own-gem/
end
