# frozen_string_literal: true

require "stringio"

RSpec.describe LlmAudit::Doctor do
  def attributes(**overrides)
    {
      check_id: :request_timeout,
      severity: :info,
      location: LlmAudit::Finding::CONFIG_LOCATION,
      message: "the seam works end to end",
      remediation: "Nothing to fix.",
      owasp_reference: "LLM06:2026 Unbounded Consumption"
    }.merge(overrides)
  end

  def build_finding(**overrides)
    LlmAudit::Finding.new(**attributes(**overrides))
  end

  def check_returning(id, result)
    Class.new do
      define_singleton_method(:id) { id }
      define_singleton_method(:inspect) { "Check_#{id}" }
      define_method(:call) { result }
    end
  end

  def counting_check(runs)
    Class.new do
      define_singleton_method(:id) { :counting }
      define_method(:call) do
        runs << :ran
        []
      end
    end
  end

  def registry_of(*checks)
    LlmAudit::Registry.new.tap { |registry| checks.each { |check| registry.register(check) } }
  end

  subject(:doctor) { described_class.new(registry: registry, formatter: formatter, io: io) }

  let(:io) { StringIO.new }
  let(:formatter) { LlmAudit::Formatters::Terminal.new }
  let(:timeout_finding) { build_finding(check_id: :request_timeout) }
  let(:retry_finding) { build_finding(check_id: :missing_retry) }
  let(:registry) do
    registry_of(check_returning(:request_timeout, [timeout_finding]), check_returning(:missing_retry, [retry_finding]))
  end

  describe "#findings" do
    it "collects the findings of every registered check, in registration order" do
      expect(doctor.findings).to eq([timeout_finding, retry_finding])
    end

    it "is empty for an empty registry" do
      doctor = described_class.new(registry: registry_of, formatter: formatter, io: io)

      expect(doctor.findings).to eq([])
    end

    it "flattens one level, so a check may report several findings" do
      registry = registry_of(check_returning(:request_timeout, [timeout_finding, retry_finding]))
      doctor = described_class.new(registry: registry, formatter: formatter, io: io)

      expect(doctor.findings).to eq([timeout_finding, retry_finding])
    end

    it "wraps a check that returns a bare Finding instead of a collection" do
      registry = registry_of(check_returning(:request_timeout, timeout_finding))
      doctor = described_class.new(registry: registry, formatter: formatter, io: io)

      expect(doctor.findings).to eq([timeout_finding])
    end

    it "treats a check that returns nil as reporting nothing" do
      registry = registry_of(check_returning(:request_timeout, nil))
      doctor = described_class.new(registry: registry, formatter: formatter, io: io)

      expect(doctor.findings).to eq([])
    end

    it "runs each check exactly once, however often it is asked" do
      runs = []
      doctor = described_class.new(registry: registry_of(counting_check(runs)), formatter: formatter, io: io)

      3.times { doctor.findings }

      expect(runs.size).to eq(1)
    end

    it "is frozen, so a caller cannot change what a later run prints" do
      expect(doctor.findings).to be_frozen
    end

    it "refuses a finding appended by a caller" do
      expect { doctor.findings << build_finding(check_id: :forged) }.to raise_error(FrozenError)
    end

    it "is public, so a caller may collect findings without printing them" do
      expect(doctor.findings).not_to be_empty
      expect(io.string).to be_empty
    end
  end

  describe "#run" do
    it "returns the findings, for the exit-code contract to build on" do
      expect(doctor.run).to eq([timeout_finding, retry_finding])
    end

    it "returns the same array #findings reports" do
      expect(doctor.run).to be(doctor.findings)
    end

    it "writes exactly the formatter's own render, plus the trailing newline" do
      doctor.run

      expect(io.string).to eq("#{formatter.call(doctor.findings)}\n")
    end

    it "writes only to the injected io, never to the process's stdout" do
      expect { doctor.run }.not_to output.to_stdout_from_any_process
    end

    it "renders through any object responding to #call, not only the terminal formatter" do
      described_class.new(registry: registry, formatter: ->(findings) { "n=#{findings.size}" }, io: io).run

      expect(io.string).to eq("n=2\n")
    end

    it "prints the same report twice, a caller having failed to inject a finding between the runs" do
      doctor.run
      expect { doctor.findings << build_finding(check_id: :forged) }.to raise_error(FrozenError)
      doctor.run

      expect(io.string).to eq("#{formatter.call([timeout_finding, retry_finding])}\n" * 2)
      expect(io.string).not_to include("forged")
    end

    it "runs the checks once across two runs" do
      runs = []
      doctor = described_class.new(registry: registry_of(counting_check(runs)), formatter: formatter, io: io)

      2.times { doctor.run }

      expect(runs.size).to eq(1)
    end

    describe "an empty registry" do
      subject(:doctor) { described_class.new(registry: registry_of, formatter: formatter, io: io) }

      it "renders the no-findings output rather than raising" do
        expect { doctor.run }.not_to raise_error

        expect(io.string).to eq("#{LlmAudit::Formatters::Terminal::NO_FINDINGS}\n")
      end
    end
  end

  describe "a check that raises" do
    def check_raising(id, error, reference: nil)
      Class.new do
        define_singleton_method(:id) { id }
        define_singleton_method(:inspect) { "Check_#{id}" }
        define_singleton_method(:owasp_reference) { reference } if reference
        define_method(:call) { raise error }
      end
    end

    def doctor_for(*checks)
      described_class.new(registry: registry_of(*checks), formatter: formatter, io: io)
    end

    let(:error) { ArgumentError.new("threshold must be a positive number") }
    let(:degraded) { doctor.findings.last }
    let(:registry) do
      registry_of(check_returning(:request_timeout, [timeout_finding]), check_raising(:missing_retry, error))
    end

    it "keeps the findings of the checks that did run" do
      expect(doctor.findings.first).to eq(timeout_finding)
    end

    it "still prints, the run having survived the failure" do
      doctor.run

      expect(io.string).to include("llm_audit: 2 findings", "request_timeout", "missing_retry")
    end

    it "degrades the raising check to exactly one undetermined finding under its own id" do
      expect(doctor.findings.size).to eq(2)
      expect(degraded).to be_undetermined
      expect(degraded.check_id).to eq(:missing_retry)
    end

    it "reports at the config location, never at a frame inside the gem" do
      expect(degraded.location).to eq(LlmAudit::Finding::CONFIG_LOCATION)
      expect(degraded).to be_symbolic_location
    end

    it "names the check and the class of the error" do
      expect(degraded.message).to include("missing_retry", "ArgumentError")
    end

    it "names the frame that raised, so the failure is locatable" do
      expect(degraded.remediation).to include("doctor_spec.rb")
    end

    it "says the check was never graded rather than that it passed" do
      expect(degraded.message).to include("undetermined, not a pass")
    end

    # Ruby 3.2 is a supported floor and a live CI leg, and there NoMethodError#message interpolates
    # receiver.inspect - so a renamed accessor on a client configuration object puts every provider API key
    # that object holds into the error's own message. Doctor reports the error's class and its frame and
    # never its message; this example is what stops that being "simplified" back. Do not delete it.
    it "repeats nothing the error itself said" do
      leaked = NoMethodError.new("undefined method `timeout' for #<Config @api_key=\"sk-SECRET-123\">")
      doctor = doctor_for(check_raising(:request_timeout, leaked))
      doctor.run

      expect(doctor.findings.last.to_h.values.join(" ")).not_to include("sk-SECRET")
      expect(io.string).not_to include("sk-SECRET")
    end

    it "falls back to a placeholder id when the check answers with something that is not a Symbol" do
      doctor = doctor_for(check_raising("request_timeout", error))

      expect(doctor.findings.map(&:check_id)).to eq([described_class::UNKNOWN_CHECK_ID])
    end

    # Registry#register asks a check for its id, so one this broken reaches Doctor only through a registry
    # that never asked - which is why Doctor asks tolerantly instead of assuming an answer. A check that
    # raised may be broken about itself, and that is the whole premise of degrading it.
    it "falls back to a placeholder id when the check cannot say what its id is" do
      check = Class.new do
        define_singleton_method(:id) { raise LlmAudit::Error, "did not declare its metadata" }
        define_method(:call) { raise ArgumentError, "threshold must be a positive number" }
      end
      doctor = described_class.new(registry: [check], formatter: formatter, io: io)

      expect(doctor.findings.map(&:check_id)).to eq([described_class::UNKNOWN_CHECK_ID])
    end

    it "falls back to a placeholder reference for a check that cannot supply one" do
      expect(degraded.owasp_reference).to eq(described_class::UNAVAILABLE_REFERENCE)
    end

    # The sibling of the id example above, and the one that keeps AC11 whole: a check may answer rather than
    # raise, and answer with text Finding refuses. Without the guard the refusal raises inside the rescue
    # body, where nothing catches it - so the other checks' findings are lost and the run prints nothing.
    it "falls back to a placeholder reference when the check answers with text a Finding would refuse" do
      doctor = doctor_for(check_raising(:missing_retry, error, reference: ""))

      expect(doctor.findings.map(&:owasp_reference)).to eq([described_class::UNAVAILABLE_REFERENCE])
    end

    it "keeps the check's own reference when it can still supply one" do
      doctor = doctor_for(check_raising(:missing_retry, error, reference: "LLM06:2026 Unbounded Consumption"))

      expect(doctor.findings.last.owasp_reference).to eq("LLM06:2026 Unbounded Consumption")
    end

    it "degrades a check whose constructor raises, not only one whose #call does" do
      check = Class.new do
        define_singleton_method(:id) { :missing_retry }
        define_method(:initialize) { raise ArgumentError, "adapters must be enumerable" }
        define_method(:call) { [] }
      end

      expect(doctor_for(check).findings.map { |finding| [finding.check_id, finding.severity] })
        .to eq([%i[missing_retry undetermined]])
    end

    it "still reports when the error carries no frame at all" do
      check = Class.new do
        define_singleton_method(:id) { :missing_retry }
        define_method(:call) { raise ArgumentError, "boom", [] }
      end

      expect(doctor_for(check).findings.last.remediation).to include(described_class::UNKNOWN_FRAME)
    end

    # Deliberately narrower than rescuing Exception: a check that never implemented #call is our bug and not
    # the host's, so it aborts loudly rather than being reported as an undetermined finding about the app.
    # It is the line Adapters::Base draws around ScriptError, held one layer up.
    it "lets a NotImplementedError abort the run" do
      check = Class.new(LlmAudit::Checks::Base) do
        declare id: :unimplemented, default_severity: :info, owasp_reference: "LLM06:2026 Unbounded Consumption"
      end

      expect { doctor_for(check).findings }.to raise_error(NotImplementedError, /must implement #call/)
    end

    it "is still frozen when a check raised" do
      expect(doctor.findings).to be_frozen
    end

    it "runs a raising check exactly once, however often it is asked" do
      runs = []
      check = Class.new do
        define_singleton_method(:id) { :counting }
        define_method(:call) do
          runs << :ran
          raise ArgumentError, "threshold must be a positive number"
        end
      end
      doctor = doctor_for(check)

      3.times { doctor.findings }

      expect(runs.size).to eq(1)
    end

    it "degrades each raising check independently" do
      doctor = doctor_for(check_raising(:request_timeout, TypeError.new("one")),
                          check_raising(:missing_retry, KeyError.new("two")))

      expect(doctor.findings.map(&:check_id)).to eq(%i[request_timeout missing_retry])
      expect(doctor.findings.map(&:message))
        .to contain_exactly(a_string_including("TypeError"), a_string_including("KeyError"))
    end
  end

  describe "its defaults" do
    it "audits the gem-wide registry" do
      findings = described_class.new(io: io).findings

      expect(findings.map(&:check_id)).to include(:request_timeout)
      expect(findings.map(&:message)).not_to include(a_string_including("did not finish"))
    end

    it "renders through the terminal formatter" do
      doctor = described_class.new(registry: registry, io: io)
      doctor.run

      expect(io.string).to eq("#{LlmAudit::Formatters::Terminal.new.call(doctor.findings)}\n")
    end

    it "writes to $stdout, resolved when the Doctor is built rather than when the file loaded" do
      expected = "#{formatter.call([timeout_finding, retry_finding])}\n"

      expect { described_class.new(registry: registry).run }.to output(expected).to_stdout
    end
  end
end
