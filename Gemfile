# frozen_string_literal: true

source "https://rubygems.org"

# Resolve this lockfile on the declared floor Ruby (3.2) and never on a newer one: `bundle update` under 3.4
# picks transitive dev gems that require >= 3.3 (rbs via irb -> rdoc, parallel via rubocop), and the 3.2 leg
# that installs from this lockfile then fails at install - CI installs frozen, so it cannot re-resolve its
# way out, and spec/ci/declared_floors_spec.rb reddens the default build if it happens. Resolve it with
# bundler 4.0.19 (`gem install bundler -v 4.0.19`): Ruby 3.2's default 2.4.10 does not know the CHECKSUMS
# section and drops all 74 entries silently, exit 0.

# Specify your gem's dependencies in llm_audit.gemspec
gemspec

gem "irb"
gem "rake", "~> 13.0"

gem "rspec", "~> 3.0"

gem "rubocop", "~> 1.21"

# Dev-only, and never required automatically: the ruby_llm adapter must be specced against the real
# RubyLLM::Configuration, but the gem-absent path is only honest in a process that has not loaded it.
gem "ruby_llm", "~> 2.0", require: false

# Same footing as ruby_llm: dev-only, never required automatically. This is the community ruby-openai gem by
# alexrudall (required as "openai", constant OpenAI) and not the official openai SDK, which needs Ruby >= 3.3
# and is M2's. spec/ci/declared_floors_spec.rb subtracts this line from the client-free bundle by name.
gem "ruby-openai", "~> 8.3", require: false
