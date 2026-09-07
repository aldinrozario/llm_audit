# frozen_string_literal: true

module LlmAudit
  module Adapters
    # Named RubyLlm and not RubyLLM on purpose: inside a class named after the client, a bare RubyLLM.config
    # would resolve to this adapter instead of the gem. The client is reached only through #client_module.
    class RubyLlm < Base
      declare id: :ruby_llm,
              gem_name: "ruby_llm",
              client_constant: "RubyLLM",
              settings: { request_timeout: :request_timeout, max_retries: :max_retries }

      # Reading RubyLLM.config materialises the client's global config (@config ||= Configuration.new), and in
      # a Rails app the client's own Railtie has already done so during boot - which is why "did this app ever
      # call configure?" cannot be answered from that object alone, and is answered instead by comparing it
      # against a pristine one. The 300s / 3 defaults are deliberately never written down here: request_timeout
      # defaulted to 120 below ruby_llm 1.9.0, so a literal would be silently wrong on those versions.
      # Both readers memoize because both compute: Configuration.new expands paths and reads ENV.
      def configuration = @configuration ||= client_module.config
      def default_configuration = @default_configuration ||= client_module::Configuration.new
    end
  end
end
