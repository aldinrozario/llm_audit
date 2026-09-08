# frozen_string_literal: true

module LlmAudit
  module Checks
    class RequestTimeout < Base
      declare id: :request_timeout,
              default_severity: :warning,
              owasp_reference: "LLM06:2026 Unbounded Consumption"

      SETTING = :request_timeout

      # 30s is Heroku's non-configurable H12 router limit and GCP's default total request timeout - a fact
      # about the platforms Rails apps are deployed on, not a round number. It flags all four known client
      # defaults (ruby-openai 120, ruby_llm 300, the official SDKs 600), so the check is never silent out of
      # the box, while the strict > below spares an app that deliberately chose 30.
      DEFAULT_THRESHOLD_SECONDS = 30

      SEVERITIES = { over: :warning, within: :info, unset: :warning, unusable: :error }.freeze

      CONFIGURE = "`%<constant>s.configure { |config| config.request_timeout = %<limit>s }`, " \
                  "conventionally in `config/initializers/%<gem>s.rb`"

      # Never "the call cannot exceed this": in the Faraday-backed clients the setting bounds one socket
      # operation, resets per chunk, and is multiplied by every retry, so a total ceiling is a claim this
      # check cannot make. What it can say is what the number costs while it is running.
      COSTS_A_WORKER = "It bounds one attempt rather than the whole call, which retries multiply, and a " \
                       "request stalled inside it holds the worker that made it."
      NO_DEADLINE = "That leaves the client no deadline of its own: what bounds a call is whatever its " \
                    "HTTP stack applies, not a value this app chose."
      FAILS_EVERY_REQUEST = "so every request through it fails on that value before it reaches a provider"

      # Keyed by provenance and classification, because the gap between the two provenances is the whole
      # point of the :configured / :defaulted split. What is graded either way is "the effective timeout is
      # N", which is provable; what a default withholds is who picked it. An app that explicitly assigns the
      # client's own default reads as :defaulted too, so the inherited wording says this app cannot be shown
      # to have chosen the value and never that it configured nothing.
      MESSAGES = {
        %i[chosen over] =>
          "the %<gem>s client is configured with a request timeout of %<observed>s, over the %<limit>ss " \
          "this check allows [%<measured>s/%<limit>s]. #{COSTS_A_WORKER}",
        %i[chosen unset] => "the %<gem>s client is configured with no finite request timeout. #{NO_DEADLINE}",
        %i[chosen unusable] => "the %<gem>s client is configured with %<observed>s, #{FAILS_EVERY_REQUEST}.",
        %i[inherited over] =>
          "the %<gem>s client runs on the client's own default request timeout of %<observed>s, which " \
          "this app cannot be shown to have chosen, and that is over the %<limit>ss this check allows " \
          "[%<measured>s/%<limit>s]. #{COSTS_A_WORKER}",
        %i[inherited within] =>
          "the %<gem>s client runs on the client's own default request timeout of %<observed>s, which " \
          "this app cannot be shown to have chosen. That is within the %<limit>ss this check allows " \
          "[%<measured>s/%<limit>s], but a default belongs to the client: a bundle update can move it " \
          "with no change to this app.",
        %i[inherited unset] =>
          "the %<gem>s client's own default is no finite request timeout, and this app cannot be shown to " \
          "have chosen otherwise. #{NO_DEADLINE}",
        %i[inherited unusable] =>
          "the %<gem>s client's own default request timeout reads as %<observed>s, which this app cannot " \
          "be shown to have chosen, #{FAILS_EVERY_REQUEST}."
      }.freeze

      REMEDIATIONS = {
        over: "Set a timeout at or below %<limit>ss: #{CONFIGURE}. If every call through this client runs " \
              "in a background job rather than a web request, a longer timeout can be deliberate: this " \
              "audit reads global configuration and cannot see the call site.",
        within: "Write the value down so it cannot move without a review: `%<constant>s.configure " \
                "{ |config| config.request_timeout = %<measured>s }`, conventionally in " \
                "`config/initializers/%<gem>s.rb`.",
        unset: "Give the client a deadline of its own, at or below %<limit>ss: #{CONFIGURE}.",
        unusable: "Set a positive number of seconds, at or below %<limit>ss: #{CONFIGURE}."
      }.freeze

      NO_SETTING = "the %<gem>s client ships no request timeout setting, so there is no value here to " \
                   "grade - not applicable rather than unknown - and nothing inside it bounds these calls."
      NO_SETTING_FIX = "Nothing to set on %<constant>s. Bound these calls from outside the client instead, " \
                       "with a Rack-level or job-level timeout."
      NOT_LOADED = "the %<gem>s client is not loaded in this process, so its request timeout could not be " \
                   "read - undetermined, not a pass."
      NOT_LOADED_FIX = "Run this audit where the app loads its client: `rails llm_audit:doctor` boots the " \
                       "host app first. If the app does not use %<gem>s at all, there is nothing to fix."
      NOT_READ = "the %<gem>s client is loaded but its request timeout could not be read, so no value was " \
                 "obtained - undetermined, not a pass."
      NOT_READ_FIX = "Check whether the installed %<gem>s still exposes `request_timeout` on its " \
                     "configuration object; a client that renamed the setting reads this way."

      # threshold is a defaulted keyword argument because Doctor builds every check with no arguments, which
      # is also how a later session injects a configured threshold without Doctor learning anything new. It
      # is deliberately unvalidated here: the file that reads a configured value is the file that owns
      # rejecting it. A threshold this check cannot compare against raises into Doctor's own degradation on
      # the two graded paths only - :unset and :unusable return from classify before the comparison, and
      # interpolate whatever they were given into the text. So this is a backstop over part of the surface
      # and not a guard over all of it; the file that accepts the value still has to reject a bad one.
      def initialize(threshold: DEFAULT_THRESHOLD_SECONDS, **)
        @threshold = threshold
        super(**)
      end

      def call = adapters.filter_map { |adapter| report(adapter, adapter.reading(SETTING)) }

      private

      attr_reader :threshold

      # Dispatch is on the state and never on #determined?, which is what keeps reading a default's number a
      # decision rather than a leak. The else is a completeness guard and not a fallback: a sixth Reading
      # state has to be graded deliberately instead of falling into whichever branch happens to be last, and
      # Doctor degrades the raise to one visible undetermined finding, so the cost is this check's findings
      # and never the run.
      def report(adapter, reading)
        case reading.state
        when Adapters::Reading::CONFIGURED  then graded(adapter, reading.value, :chosen)
        when Adapters::Reading::DEFAULTED   then graded(adapter, reading.default, :inherited)
        when Adapters::Reading::UNSUPPORTED then not_applicable(adapter)
        when Adapters::Reading::ABSENT      then not_loaded(adapter)
        when Adapters::Reading::UNREADABLE  then not_read(adapter)
        else raise Error, "#{self.class.inspect} has no verdict for a #{reading.state.inspect} reading"
        end
      end

      # The one silent branch in the check: a value the app chose, inside the limit, is the thing this check
      # exists to find nothing wrong with. An inherited value inside the limit is not silent, because
      # nothing here shows the app would notice if the client moved it.
      def graded(adapter, value, provenance)
        classification = classify(value)
        return if provenance == :chosen && classification == :within

        texts = rendered(adapter, value, MESSAGES.fetch([provenance, classification]),
                         REMEDIATIONS.fetch(classification))

        finding(severity: SEVERITIES.fetch(classification), **texts)
      end

      # nil first, because `nil > 30` raises and a :configured reading may legitimately carry nil. Numeric
      # before positive?, because "600" is stored uncoerced and comparing it raises too; real? before
      # positive?, because Complex#positive? raises rather than answering. finite? last, and the only value
      # still standing there is +Infinity: nil makes Faraday skip the option so the HTTP stack's own default
      # applies, but Infinity is truthy and is handed down, where Net::HTTP raises RangeError on every
      # request. So it is unusable like 0 and "600", and never unset like nil, whose branch says the app
      # chose no value at all. Not printable either, so [Infinity/30] still never renders as a measurement.
      def classify(value)
        return :unset if value.nil?
        return :unusable unless value.is_a?(Numeric) && value.real? && value.positive?
        return :unusable unless value.finite?

        value > threshold ? :over : :within
      end

      def not_applicable(adapter) = finding(severity: :info, **rendered(adapter, nil, NO_SETTING, NO_SETTING_FIX))
      def not_loaded(adapter) = undetermined(**rendered(adapter, nil, NOT_LOADED, NOT_LOADED_FIX))
      def not_read(adapter) = undetermined(**rendered(adapter, nil, NOT_READ, NOT_READ_FIX))

      # The client is named from the adapter's own declaration and never read off a configuration object,
      # which inspects every provider credential it holds. A value reaches the report only when it is a
      # finite real number: anything else is described by its class, so a String an app put in the setting
      # is never echoed into a report that gets pasted into a ticket.
      def rendered(adapter, value, message, remediation)
        text = { gem: adapter.class.gem_name, constant: adapter.class.client_constant, limit: threshold,
                 measured: (measured(value) if printable?(value)), observed: observed(value) }

        { location: Finding::CONFIG_LOCATION, message: format(message, **text),
          remediation: format(remediation, **text) }
      end

      def printable?(value) = value.is_a?(Numeric) && value.real? && value.finite?

      # printable? admits any finite real Numeric, and the two beyond Integer and Float print in their own
      # notation: BigDecimal("300") is "0.3e3" and Rational(600, 1) is "600/1", which inside [600/1/30] reads
      # as a nested fraction rather than a measurement. Both are rendered as the Integer or Float the same
      # number would have been written as. Safe on every printable value, since to_i is what raises on the
      # infinite and NaN this excludes.
      def measured(value) = value.to_i == value ? value.to_i : value.to_f

      def observed(value)
        printable?(value) ? "#{measured(value)}s" : "a #{value.class} rather than a positive number of seconds"
      end
    end
  end
end
