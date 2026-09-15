# frozen_string_literal: true

module LlmAudit
  module Adapters
    # Named after the gem, ruby-openai, and never after its constant: OpenAI is also the constant the official
    # openai SDK claims, and an adapter called OpenAI would shadow the client it reads. Reached only through
    # #client_module, like RubyLlm. A host that loaded the official SDK instead reads back through Base's rescue
    # as loaded but unreadable, never as a pass; telling the two shapes apart is where M2 grows the vocabulary.
    class RubyOpenai < Base
      # max_output_tokens is nil for ruby_llm's reason: no client-wide output cap, a cap is per request.
      # max_retries maps to a real accessor and yet the client ships no retry setting - retry is faraday-retry
      # middleware the host adds to the connection, or it is nothing - so the accessor reads the middleware
      # and #ships? says whether there is one to read.
      declare id: :ruby_openai,
              gem_name: "ruby-openai",
              client_constant: "OpenAI",
              settings: { request_timeout: :request_timeout, max_retries: :max_retries, max_output_tokens: nil }

      # The middleware's name on faraday-retry (Faraday 2.x, and 1.9+ where it became a gem) and on Faraday's
      # own below 1.9. Names and never the constants: neither exists on a host that loaded no retry middleware,
      # which is exactly the host this reading has to describe.
      RETRY_MIDDLEWARE = %w[Faraday::Retry::Middleware Faraday::Request::Retry].freeze

      # Not OpenAI.configuration itself: Base reads one accessor off the live and the pristine object alike,
      # and the client's configuration has no max_retries. The facade answers both, and answers the retry
      # count lazily, so building a client to read it - which raises below ruby-openai 7.0 with no token, and
      # runs whatever the host's middleware block does - never costs the timeout its reading. It holds the
      # timeout and never the configuration object, whose inspect prints every token it was given.
      class Facade
        attr_reader :request_timeout

        def initialize(request_timeout, &max_retries)
          @request_timeout = request_timeout
          @max_retries = max_retries
        end

        def max_retries = @max_retries&.call
      end

      # OpenAI.configuration is `@configuration ||= Configuration.new`, materialised by the first client the app
      # built or by this read - ruby-openai has no Railtie, so nothing at boot does it; the 120s default is never
      # written down here. No retry count on the pristine side, since the client ships none of its own.
      def configuration
        @configuration ||= Facade.new(client_module.configuration.request_timeout) { retry_count }
      end

      def default_configuration
        @default_configuration ||= Facade.new(client_module::Configuration.new.request_timeout)
      end

      private

      def ships?(setting) = setting != :max_retries || !retry_handler.nil?

      # The raw max and never the middleware's own fallback: nil is what the app wrote, and what the middleware
      # then substitutes is the HTTP stack's number, not a value this app chose. build(nil) constructs the
      # middleware with no app behind it - no request is made - and is the one read of its options that
      # Faraday 1.10 and 2.x share. Not nil-safe on purpose: a host with no middleware has no count to read,
      # and a nil here would make it one the app wrote. That host is #ships?' answer, asked by Base before
      # this is read, so the raise is reached only by reading the facade directly, which Base's readers are
      # not for.
      def retry_count = retry_handler.build(nil).options[:max]

      # Matched by ancestry and never by handler name or position: a host's subclass of the middleware is still
      # the middleware, and a `f.request :url_encoded` after it moves it off the end of the stack. Memoized on
      # defined? because nil - no middleware - is the common answer and must not be recomputed.
      def retry_handler
        return @retry_handler if defined?(@retry_handler)

        @retry_handler = connection.builder.handlers.find do |handler|
          handler.klass.ancestors.any? { |ancestor| RETRY_MIDDLEWARE.include?(ancestor.name) }
        end
      end

      # The client's real, private #conn rather than a connection rebuilt from what it is known to do: only that
      # sees a reopened #conn, or a builder the host installed through Faraday.default_connection_options. A
      # block passed to OpenAI::Client.new inside the app is not seen - a doctor-time read sees the client the
      # global configuration builds. Construction only: no request leaves and no token is needed. Memoized
      # because the host's block runs on every #conn.
      def connection = @connection ||= client_module::Client.new.send(:conn)
    end
  end
end
