# frozen_string_literal: true

RSpec.describe LlmAudit::Checks::Scaffold do
  describe "the check contract" do
    it "is a check" do
      expect(described_class.ancestors).to include(LlmAudit::Checks::Base)
    end

    it "declares its metadata, readable without instantiating the check" do
      expect(described_class).not_to receive(:new)

      expect([described_class.id, described_class.default_severity, described_class.owasp_reference])
        .to eq([:scaffold, :info, "LLM10:2025 Unbounded Consumption"])
    end

    it "is readable through the registry without instantiating the check" do
      registered = LlmAudit.registry.fetch(:scaffold)
      expect(registered).not_to receive(:new)

      expect([registered.id, registered.default_severity, registered.owasp_reference])
        .to eq([:scaffold, :info, "LLM10:2025 Unbounded Consumption"])
    end

    it "grades itself :info, because scaffolding is not a risk" do
      expect(described_class.default_severity).to eq(:info)
    end
  end

  describe "#call" do
    subject(:findings) { described_class.new.call }

    it "returns exactly one finding" do
      expect(findings.size).to eq(1)
    end

    it "returns Findings" do
      expect(findings).to all(be_a(LlmAudit::Finding))
    end

    it "stamps the finding with its own id, severity and owasp reference" do
      finding = findings.first

      expect([finding.check_id, finding.severity, finding.owasp_reference])
        .to eq([:scaffold, :info, "LLM10:2025 Unbounded Consumption"])
    end

    it "reports against the symbolic config location, having inspected no file" do
      finding = findings.first

      expect([finding.location, finding.symbolic_location?])
        .to eq([LlmAudit::Finding::CONFIG_LOCATION, true])
    end

    it "is a determined finding, not an undetermined one" do
      expect(findings.first).not_to be_undetermined
    end

    it "says in its message that it is scaffolding" do
      expect(findings.first.message).to include("scaffolding")
    end

    it "names the issue that replaces it in its remediation" do
      expect(findings.first.remediation).to include("Issue #4")
    end

    it "returns the same finding every run, having no state to vary on" do
      expect(described_class.new.call).to eq(described_class.new.call)
    end
  end
end
