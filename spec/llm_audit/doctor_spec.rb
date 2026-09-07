# frozen_string_literal: true

require "stringio"

RSpec.describe LlmAudit::Doctor do
  def attributes(**overrides)
    {
      check_id: :scaffold,
      severity: :info,
      location: LlmAudit::Finding::CONFIG_LOCATION,
      message: "the seam works end to end",
      remediation: "Nothing to fix.",
      owasp_reference: "LLM10:2025 Unbounded Consumption"
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

  describe "its defaults" do
    it "audits the gem-wide registry" do
      expect(described_class.new(io: io).findings.map(&:check_id)).to include(:scaffold)
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
