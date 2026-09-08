# frozen_string_literal: true

require_relative "lib/llm_audit/version"

Gem::Specification.new do |spec|
  spec.name = "llm_audit"
  spec.version = LlmAudit::VERSION
  spec.authors = ["Aldin A Rozario"]
  spec.email = ["aldinrozario76@gmail.com"]

  spec.summary = "Audit Rails apps that call LLMs for unbounded consumption, leaked keys, and unsafe AI surfaces."
  spec.description = "Catches the security and reliability risks unique to Rails apps that call LLMs: " \
                     "unbounded requests (timeouts, retries, token and cost caps), leaked provider keys, " \
                     "unauthorized AI tool surfaces, and model output reaching trusted sinks. Ships a " \
                     "`rails llm_audit:doctor` task that inspects the running app, with findings mapped " \
                     "to the OWASP LLM Top 10."
  spec.homepage = "https://github.com/aldinrozario/llm_audit"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"
  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/aldinrozario/llm_audit"
  spec.metadata["changelog_uri"] = "https://github.com/aldinrozario/llm_audit/blob/main/CHANGELOG.md"

  # Uncomment the line below to require MFA for gem pushes.
  # This helps protect your gem from supply chain attacks by ensuring
  # no one can publish a new version without multi-factor authentication.
  # See: https://guides.rubygems.org/mfa-requirement-opt-in/
  spec.metadata["rubygems_mfa_required"] = "true"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  gemspec = File.basename(__FILE__)

  # `gemfiles/` is listed separately from `Gemfile`: start_with? is case-sensitive, so the capital-G entry
  # never matches it and the CI matrix's gemfiles would otherwise ship inside the released gem.
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ Gemfile gemfiles/ .gitignore .rspec spec/ .github/ .rubocop.yml])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "railties", ">= 7.1", "< 9"

  # For more information and examples about making a new gem, check out our
  # guide at: https://guides.rubygems.org/make-your-own-gem/
end
