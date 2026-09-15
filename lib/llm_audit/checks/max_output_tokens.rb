# frozen_string_literal: true

module LlmAudit
  module Checks
    class MaxOutputTokens < Base
      declare id: :max_output_tokens,
              default_severity: :warning,
              owasp_reference: "LLM06:2026 Unbounded Consumption"

      SETTING = :max_output_tokens

      # No blessed M1 client exposes a global output-token cap, so against ruby_llm this number reaches the
      # report only through the not-applicable remediation, as the ceiling to give every call. 4096 is the cap
      # ruby_llm's own Anthropic provider falls back to when a request states none and the model registry has
      # no answer - a bound a provider integration chose, not a round number. The graded branches below
      # compare against it the moment a client with a global cap, or the M2 cop reading a call site, hands
      # one in; until then only a fabricated adapter reaches them.
      DEFAULT_THRESHOLD_TOKENS = 4096

      SEVERITIES = { over: :warning, within: :info, unset: :warning, unusable: :error }.freeze

      CONFIGURE = "`%<constant>s.configure { |config| config.max_output_tokens = %<limit>s }`, " \
                  "conventionally in `config/initializers/%<gem>s.rb`"

      COSTS_PER_TOKEN = "Every output token is billed and takes time to generate, so the cap is the one " \
                        "bound on what a single response can cost."
      NO_CAP = "Nothing this app set bounds the tokens a response may consume, so what bounds them is the " \
               "model's own ceiling, or nothing."
      # Starts at "so": every message that embeds it has just rendered %<observed>s, which for a non-number already
      # says it is not a positive count of tokens; for 0 or a negative count the remediation says "positive".
      # Hedged like the retry check's NOT_A_COUNT: the providers refuse 0, a negative count and a String, Ruby's
      # JSON generator raises on Infinity and NaN before a request leaves, and a client that coerced the String
      # would cap on a number this app never wrote - which of those applies is the client's, not this check's.
      NOT_A_CAP = "so what the client makes of it - failing every request on it, or capping on a number nobody " \
                  "wrote down - is not something this check can grade"

      MESSAGES = {
        %i[chosen over] =>
          "the %<gem>s client is configured with an output-token cap of %<observed>s, over the %<limit>s " \
          "tokens this check allows [%<measured>s/%<limit>s]. #{COSTS_PER_TOKEN}",
        %i[chosen unset] => "the %<gem>s client is configured with no output-token cap. #{NO_CAP}",
        %i[chosen unusable] =>
          "the %<gem>s client is configured with %<observed>s as its output-token cap, #{NOT_A_CAP}.",
        %i[inherited over] =>
          "the %<gem>s client runs on the client's own default output-token cap of %<observed>s, which this " \
          "app cannot be shown to have chosen, and that is over the %<limit>s tokens this check allows " \
          "[%<measured>s/%<limit>s]. #{COSTS_PER_TOKEN}",
        %i[inherited within] =>
          "the %<gem>s client runs on the client's own default output-token cap of %<observed>s, which this " \
          "app cannot be shown to have chosen. That is within the %<limit>s tokens this check allows " \
          "[%<measured>s/%<limit>s], but a default belongs to the client: a bundle update can move it with " \
          "no change to this app.",
        %i[inherited unset] =>
          "the %<gem>s client's own default is no output-token cap, and this app cannot be shown to have " \
          "chosen otherwise. #{NO_CAP}",
        %i[inherited unusable] =>
          "the %<gem>s client's own default output-token cap reads as %<observed>s, which this app cannot " \
          "be shown to have chosen, #{NOT_A_CAP}."
      }.freeze

      REMEDIATIONS = {
        over: "Set a cap at or below %<limit>s tokens: #{CONFIGURE}. If one call genuinely needs a longer " \
              "response, raise the cap at that call and not for every call the client makes.",
        within: "Write the value down so it cannot move without a review: `%<constant>s.configure " \
                "{ |config| config.max_output_tokens = %<measured>s }`, conventionally in " \
                "`config/initializers/%<gem>s.rb`.",
        unset: "Give the client a cap of its own, at or below %<limit>s tokens: #{CONFIGURE}.",
        unusable: "Set a positive whole number of tokens, at or below %<limit>s: #{CONFIGURE}."
      }.freeze

      # The one :unsupported in this family graded at the check's own severity rather than as an :info
      # not-applicable: a client with no global cap leaves every call uncapped unless the call says otherwise,
      # and a per-call cap is written at a call site this audit cannot see. Anthropic's API refuses a request
      # with no cap, so a client that ships none is either failing those calls or capping them out of view.
      NO_SETTING = "the %<gem>s client ships no global output-token cap, so nothing this app configured " \
                   "bounds the tokens a response may consume: whatever cap applies is set per call, or is " \
                   "the provider's own, and neither is visible to this audit. Anthropic's API requires one " \
                   "on every request; the other providers fall back to the model's own ceiling."
      NO_SETTING_FIX = "Nothing to set on %<constant>s globally. Pass a `max_tokens`-style cap on every " \
                       "call, at or below %<limit>s tokens, and keep it where a review can see it - a cap " \
                       "this audit cannot read is one a code-level audit has to find."
      NOT_LOADED = "the %<gem>s client is not loaded in this process, so its output-token cap could not be " \
                   "read - undetermined, not a pass."
      NOT_LOADED_FIX = "Run this audit where the app loads its client: `rails llm_audit:doctor` boots the " \
                       "host app first. If the app does not use %<gem>s at all, there is nothing to fix."
      NOT_READ = "the %<gem>s client is loaded but its output-token cap could not be read, so no value was " \
                 "obtained - undetermined, not a pass."
      NOT_READ_FIX = "Check whether the installed %<gem>s still exposes an output-token cap on its " \
                     "configuration object; a client that renamed the setting reads this way."

      # Same contract as RequestTimeout#initialize: defaulted so Doctor builds it with no arguments, and
      # deliberately unvalidated - the file that reads a configured value owns rejecting it.
      def initialize(threshold: DEFAULT_THRESHOLD_TOKENS, **)
        @threshold = threshold
        super(**)
      end

      def call = adapters.filter_map { |adapter| report(adapter, adapter.reading(SETTING)) }

      private

      attr_reader :threshold

      def report(adapter, reading)
        case reading.state
        when Adapters::Reading::CONFIGURED  then graded(adapter, reading.effective, :chosen)
        when Adapters::Reading::DEFAULTED   then graded(adapter, reading.effective, :inherited)
        when Adapters::Reading::UNSUPPORTED then uncapped(adapter)
        when Adapters::Reading::ABSENT      then not_loaded(adapter)
        when Adapters::Reading::UNREADABLE  then not_read(adapter)
        else raise Error, "#{self.class.inspect} has no verdict for a #{reading.state.inspect} reading"
        end
      end

      def graded(adapter, value, provenance)
        classification = classify(value)
        return if provenance == :chosen && classification == :within

        texts = rendered(adapter, value, MESSAGES.fetch([provenance, classification]),
                         REMEDIATIONS.fetch(classification))

        finding(severity: SEVERITIES.fetch(classification), **texts)
      end

      # The timeout's table, because a cap has its shape: nil is a cap the app chose not to set, a String or a
      # Complex is not a count, 0 and a negative count are refused by every provider - a response of no tokens
      # is not a bound - and Infinity is no cap either. finite? last for the same reason as there.
      def classify(value)
        return :unset if value.nil?
        return :unusable unless value.is_a?(Numeric) && value.real? && value.positive?
        return :unusable unless value.finite?

        value > threshold ? :over : :within
      end

      def uncapped(adapter) = finding(**rendered(adapter, nil, NO_SETTING, NO_SETTING_FIX))
      def not_loaded(adapter) = undetermined(**rendered(adapter, nil, NOT_LOADED, NOT_LOADED_FIX))
      def not_read(adapter) = undetermined(**rendered(adapter, nil, NOT_READ, NOT_READ_FIX))

      def rendered(adapter, value, message, remediation)
        text = { gem: adapter.class.gem_name, constant: adapter.class.client_constant, limit: threshold,
                 measured: (measured(value) if printable?(value)), observed: observed(value) }

        { location: Finding::CONFIG_LOCATION, message: format(message, **text),
          remediation: format(remediation, **text) }
      end

      def observed(value)
        printable?(value) ? measured(value).to_s : "a #{value.class} rather than a positive count of tokens"
      end
    end
  end
end
