# frozen_string_literal: true

module LlmAudit
  module Checks
    class MaxRetries < Base
      declare id: :max_retries,
              default_severity: :warning,
              owasp_reference: "LLM06:2026 Unbounded Consumption"

      SETTING = :max_retries

      # 3 is the widest retry count any blessed client ships as its own default (ruby_llm 3, the official SDKs
      # 2, ruby-openai none), so a client on its defaults grades :info through the inherited branch rather
      # than :warning on the number alone - and is still never silent, because a default is never silent. The
      # strict > below spares an app that deliberately chose that ceiling. Nothing in this setting can mean
      # "unbounded"; a large count is the only way to write it, and this comparison is what catches it.
      DEFAULT_THRESHOLD_RETRIES = 3

      SEVERITIES = { over: :warning, within: :info, unset: :warning, unusable: :error }.freeze

      CONFIGURE = "`%<constant>s.configure { |config| config.max_retries = %<limit>s }`, " \
                  "conventionally in `config/initializers/%<gem>s.rb`"

      # The retry half of the timeout check's caveat: every retry repeats the whole attempt, timeout included.
      MULTIPLIES_THE_TIMEOUT = "Every retry repeats the whole attempt, request timeout included, so one call " \
                               "can hold its worker for the timeout multiplied by one more than this count."
      # nil is neither zero nor unbounded: the Faraday-backed clients hand it to the retry middleware, which
      # substitutes a default of its own. Whose number then applies is the HTTP stack's, so the text says
      # that and never a count.
      NO_COUNT = "How many times a failed call is retried is then whatever its HTTP stack applies, not a " \
                 "value this app chose."
      # Starts at "so": every message that embeds it has just rendered %<observed>s, which already says the value
      # is not a count of retries.
      NOT_A_COUNT = "so what the client makes of it - failing every request on it, or retrying on a number " \
                    "nobody wrote down - is not something this check can grade"

      MESSAGES = {
        %i[chosen over] =>
          "the %<gem>s client is configured with a retry count of %<observed>s, over the %<limit>s retries " \
          "this check allows [%<measured>s/%<limit>s]. #{MULTIPLIES_THE_TIMEOUT}",
        %i[chosen unset] => "the %<gem>s client is configured with no retry count of its own. #{NO_COUNT}",
        %i[chosen unusable] => "the %<gem>s client is configured with %<observed>s, #{NOT_A_COUNT}.",
        %i[inherited over] =>
          "the %<gem>s client runs on the client's own default retry count of %<observed>s, which this app " \
          "cannot be shown to have chosen, and that is over the %<limit>s retries this check allows " \
          "[%<measured>s/%<limit>s]. #{MULTIPLIES_THE_TIMEOUT}",
        %i[inherited within] =>
          "the %<gem>s client runs on the client's own default retry count of %<observed>s, which this app " \
          "cannot be shown to have chosen. That is within the %<limit>s retries this check allows " \
          "[%<measured>s/%<limit>s], but a default belongs to the client: a bundle update can move it with " \
          "no change to this app.",
        %i[inherited unset] =>
          "the %<gem>s client's own default is no retry count, and this app cannot be shown to have chosen " \
          "otherwise. #{NO_COUNT}",
        %i[inherited unusable] =>
          "the %<gem>s client's own default retry count reads as %<observed>s, which this app cannot be " \
          "shown to have chosen, #{NOT_A_COUNT}."
      }.freeze

      REMEDIATIONS = {
        over: "Set a retry count at or below %<limit>s: #{CONFIGURE}. Retries are for transient failures - " \
              "a rate limit, a 5xx, a timeout - and each one is a full attempt, so a larger count buys a " \
              "longer stall before the same error.",
        within: "Write the value down so it cannot move without a review: `%<constant>s.configure " \
                "{ |config| config.max_retries = %<measured>s }`, conventionally in " \
                "`config/initializers/%<gem>s.rb`.",
        unset: "Give the client a retry count of its own, at or below %<limit>s: #{CONFIGURE}.",
        unusable: "Set a whole number of retries, at or below %<limit>s: #{CONFIGURE}."
      }.freeze

      # :unsupported has teeth here that it does not have for the timeout: a client that ships no retry
      # setting retries nothing, so a transient failure surfaces on the first attempt. A fact and a finding,
      # graded below the number-based branches because bounded is the opposite of what this family hunts.
      NO_RETRIES = "the %<gem>s client ships no retry setting, so a failed call is never retried by the " \
                   "client: a transient failure - a rate limit, a 5xx, a timeout - surfaces on the first " \
                   "attempt. Bounded, and never a pass: nothing inside the client retries, and nothing " \
                   "this app configured says whether it wanted that."
      NO_RETRIES_FIX = "Nothing to set on %<constant>s. If transient failures should be retried, retry from " \
                       "outside the client - a job-level retry with a ceiling at or below %<limit>s - and " \
                       "remember each attempt runs the full request timeout."
      NOT_LOADED = "the %<gem>s client is not loaded in this process, so its retry count could not be " \
                   "read - undetermined, not a pass."
      NOT_LOADED_FIX = "Run this audit where the app loads its client: `rails llm_audit:doctor` boots the " \
                       "host app first. If the app does not use %<gem>s at all, there is nothing to fix."
      NOT_READ = "the %<gem>s client is loaded but its retry count could not be read, so no value was " \
                 "obtained - undetermined, not a pass."
      NOT_READ_FIX = "Check whether the installed %<gem>s still exposes `max_retries` on its configuration " \
                     "object; a client that renamed the setting reads this way."

      # Same contract as RequestTimeout#initialize: defaulted so Doctor builds it with no arguments, and
      # deliberately unvalidated - the file that reads a configured value owns rejecting it.
      def initialize(threshold: DEFAULT_THRESHOLD_RETRIES, **)
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
        when Adapters::Reading::UNSUPPORTED then no_retries(adapter)
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

      # Not the timeout's table. nil first, because a :configured reading may carry nil and `nil > 3` raises;
      # for retries it is neither zero nor unbounded, so it is :unset with prose that names no number. No
      # positive? guard: 0 and a negative count are bounded - the client retries nothing on either - so they
      # sit inside the limit rather than beside a String, unlike a 0s timeout, which no request can use.
      # finite? last: Infinity and NaN are Numeric and real, and the retry middleware's to_i raises on both
      # before the first request leaves, so they are :unusable and never the "unbounded" they look like. A
      # fractional count is compared as written, never through that to_i: 3.5 would run as the 3 the strict >
      # spares, but 3.5 is what the app wrote, and a retry count that is not a whole number is itself the
      # anomaly - [3.5/3] is what shows it, and the remediation's literal `= 3` is the whole number to write.
      def classify(value)
        return :unset if value.nil?
        return :unusable unless value.is_a?(Numeric) && value.real? && value.finite?

        value > threshold ? :over : :within
      end

      def no_retries(adapter) = finding(severity: :info, **rendered(adapter, nil, NO_RETRIES, NO_RETRIES_FIX))
      def not_loaded(adapter) = undetermined(**rendered(adapter, nil, NOT_LOADED, NOT_LOADED_FIX))
      def not_read(adapter) = undetermined(**rendered(adapter, nil, NOT_READ, NOT_READ_FIX))

      def rendered(adapter, value, message, remediation)
        text = { gem: adapter.class.gem_name, constant: adapter.class.client_constant, limit: threshold,
                 measured: (measured(value) if printable?(value)), observed: observed(value) }

        { location: Finding::CONFIG_LOCATION, message: format(message, **text),
          remediation: format(remediation, **text) }
      end

      def observed(value)
        printable?(value) ? measured(value).to_s : "a #{value.class} rather than a count of retries"
      end
    end
  end
end
