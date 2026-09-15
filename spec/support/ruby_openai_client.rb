# frozen_string_literal: true

# The one place in the suite that loads ruby-openai: the community gem by alexrudall, whose require name is
# "openai" and whose constant is OpenAI - both also claimed by the official openai SDK, which the Gemfile does
# not carry (`require "ruby-openai"` is a LoadError on every version of the community gem). Declared
# `require: false` for ruby_llm's reason: every other spec file must be free to observe its absence.
# faraday-retry is loaded here too, because ruby-openai retries only through that middleware when the host
# adds it, and the examples standing in for such a host need `:retry` registered; nothing here adds it to
# any connection. It reaches this bundle through ruby_llm's own dependency and never through the Gemfile,
# which does not name it - ruby-openai does not depend on it, and the adapter spec pins that - so a ruby_llm
# that dropped it would fail this require, not that spec. No Railtie, so load order against Rails is
# irrelevant for this client.
require "openai"
require "faraday/retry"

module RubyOpenaiConfigIsolation
  # Reports option NAMES and never their values: the configuration carries the access and admin tokens, and
  # its own inspect prints them.
  def self.leaked_options(configuration)
    pristine = OpenAI::Configuration.new

    options.reject { |option| configuration.public_send(option) == pristine.public_send(option) }
  end

  def self.options = @options ||= OpenAI::Configuration.public_instance_methods(false).grep_v(/=\z/)
end

# OpenAI.configuration is a process-global `@configuration ||= Configuration.new` behind an attr_writer, so the
# swap is the writer and the restore is the writer; restoring nil puts back "nothing had touched it yet". The
# leak guard runs ahead of the swap, the only moment the inherited global is still visible. No logger or other
# module-level memo to swap, unlike ruby_llm_client.rb.
RSpec.shared_context "with a pristine OpenAI configuration" do
  around do |example|
    configuration = OpenAI.instance_variable_get(:@configuration)
    leaked = configuration ? RubyOpenaiConfigIsolation.leaked_options(configuration) : []
    raise "OpenAI.configuration was left mutated by an earlier example: #{leaked.inspect}" unless leaked.empty?

    OpenAI.configuration = OpenAI::Configuration.new
    example.run
  ensure
    OpenAI.configuration = configuration
  end
end
