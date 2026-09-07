# frozen_string_literal: true

# The one place in the suite that loads the client: the Gemfile declares it `require: false` precisely so that
# requiring "llm_audit" never drags it in, and every other spec must be free to observe its absence. It runs at
# file-load time, so RubyLLM is defined for every example - and, load order being what it is, before anything
# has required "rails": ruby_llm pulls in its own Railtie only `if defined?(Rails::Railtie)`, and RSpec loads
# spec/llm_audit/** ahead of spec/tasks/**, which is what loads Rails. Require this file from somewhere that
# boots Rails first and the client's Railtie comes along, touching RubyLLM.config during boot.
require "ruby_llm"

module RubyLlmConfigIsolation
  # Reports option NAMES and never their values: RubyLLM::Configuration carries 59 options, among them every
  # provider's api key, secret and session token, and nothing this gem prints may contain a credential.
  def self.leaked_options(config)
    pristine = RubyLLM::Configuration.new

    RubyLLM::Configuration.options.reject { |option| config.public_send(option) == pristine.public_send(option) }
  end
end

# RubyLLM.config is a process-global `@config ||= Configuration.new`, so an example that calls
# RubyLLM.configure leaks into every later example unless the global is swapped out and put back. Any example
# that mutates the client's configuration must include this context. The leak guard runs here rather than as a
# canary example because this is the only point at which the INHERITED global is still visible - after the
# swap every example starts from a fresh object, so nothing an example can assert about RubyLLM.config could
# ever fail. A spec that mutates the config without including this context therefore fails every example that
# does include it, naming the leaked options. An exception mid-example still restores through `ensure`, and
# restoring nil is the correct outcome when nothing in the process had touched the config yet. RSpec's
# `around` wraps constant teardown, so RubyLLM is back in place before `ensure` runs even in a hide_const
# example. RubyLLM.logger is swapped too: it is a second module-level memo, `@logger ||= config.logger || ...`,
# and would otherwise pin a logger built from a configuration this context is about to discard. RubyLLM's
# other memo, @deprecator, holds no configuration and needs no containment.
RSpec.shared_context "with a pristine RubyLLM configuration" do
  around do |example|
    config = RubyLLM.instance_variable_get(:@config)
    logger = RubyLLM.instance_variable_get(:@logger)
    leaked = config ? RubyLlmConfigIsolation.leaked_options(config) : []
    raise "RubyLLM.config was left mutated by an earlier example: #{leaked.inspect}" unless leaked.empty?

    RubyLLM.instance_variable_set(:@config, RubyLLM::Configuration.new)
    RubyLLM.instance_variable_set(:@logger, nil)
    example.run
  ensure
    RubyLLM.instance_variable_set(:@config, config)
    RubyLLM.instance_variable_set(:@logger, logger)
  end
end
