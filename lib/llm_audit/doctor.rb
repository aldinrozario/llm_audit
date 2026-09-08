# frozen_string_literal: true

module LlmAudit
  class Doctor
    UNKNOWN_CHECK_ID = :unknown_check
    UNAVAILABLE_REFERENCE = "OWASP reference unavailable"
    UNKNOWN_FRAME = "a frame the error did not record"

    RAISED = "the %<check>s check raised %<error>s and did not finish, so whatever it audits was never " \
             "graded - undetermined, not a pass."
    RAISED_FIX = "Report this against llm_audit rather than changing the app: a check that raises is a " \
                 "fault in the audit and not in what it audits. It raised at %<frame>s. The error's own " \
                 "message is deliberately not repeated here, because an exception raised against a " \
                 "client's configuration object carries that object's inspect, and that inspect holds " \
                 "every API key it was given."

    def initialize(registry: LlmAudit.registry, formatter: Formatters::Terminal.new, io: $stdout)
      @registry = registry
      @formatter = formatter
      @io = io
    end

    def run
      io.puts(formatter.call(findings))
      findings
    end

    def findings
      @findings ||= registry.flat_map { |check| Array(run_check(check)) }.freeze
    end

    private

    attr_reader :registry, :formatter, :io

    # A raising check costs its own findings and not the run's: the adapter layer already degrades client
    # drift to an unreadable reading, and this is that promise one layer up. StandardError only, so a check
    # that never implemented #call still aborts loudly - a NotImplementedError is our bug and not the host's,
    # which is the same line Adapters::Base draws around ScriptError. The rescue wraps the per-check call
    # alone, so a formatter or registry failure still aborts the run, correctly.
    def run_check(check)
      check.new.call
    rescue StandardError => e
      degraded(check, e)
    end

    # The error's class and the frame it raised at are reported; its message never is. On Ruby 3.2 - a
    # supported floor and a live CI leg - NoMethodError#message interpolates receiver.inspect, and a client
    # configuration object holds every provider's API key. A renamed client accessor is the most likely
    # exception in this layer, so the error most likely to arrive here is exactly the one that would print a
    # key into the report, on exactly the Ruby where it leaks. Never interpolate error.message.
    def degraded(check, error)
      check_id = declared(check, :id) { |value| value.is_a?(Symbol) } || UNKNOWN_CHECK_ID
      reference = declared(check, :owasp_reference) { |value| Finding.valid_text?(value) }

      Finding.undetermined(check_id: check_id, location: Finding::CONFIG_LOCATION,
                           message: format(RAISED, check: check_id, error: error.class),
                           remediation: format(RAISED_FIX, frame: error.backtrace&.first || UNKNOWN_FRAME),
                           owasp_reference: reference || UNAVAILABLE_REFERENCE)
    end

    # A check that raised may be broken about itself, so nothing here may assume it can answer: Doctor's
    # contract on a check is .id / .new / #call, and a bare check.owasp_reference raises NoMethodError
    # inside the rescue above - taking down the very run this degradation exists to save.
    def declared(check, name)
      value = check.public_send(name)
      value if yield(value)
    rescue StandardError
      nil
    end
  end
end
