# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in llm_audit.gemspec
gemspec

gem "irb"
gem "rake", "~> 13.0"

gem "rspec", "~> 3.0"

gem "rubocop", "~> 1.21"

# Dev-only, and never required automatically: the ruby_llm adapter must be specced against the real
# RubyLLM::Configuration, but the gem-absent path is only honest in a process that has not loaded it.
gem "ruby_llm", "~> 1.16", require: false
