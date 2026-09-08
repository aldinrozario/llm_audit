# frozen_string_literal: true

RSpec.describe LlmAudit::Finding do
  def attributes(**overrides)
    {
      check_id: :request_timeout,
      severity: :warning,
      location: "config/initializers/ruby_llm.rb:12",
      message: "the client timeout is 300s",
      remediation: "Set a timeout below the web request budget.",
      owasp_reference: "LLM10:2025 Unbounded Consumption"
    }.merge(overrides)
  end

  def build(**overrides)
    described_class.new(**attributes(**overrides))
  end

  describe "the six fields" do
    it "carries exactly check_id, severity, location, message, remediation and owasp_reference" do
      expect(build.to_h.keys).to eq(%i[check_id severity location message remediation owasp_reference])
    end

    it "exposes every field unchanged" do
      expect(build).to have_attributes(attributes)
    end

    it "requires every field" do
      expect { described_class.new(**attributes.except(:owasp_reference)) }
        .to raise_error(ArgumentError, /missing keyword: :owasp_reference/)
    end

    it "is frozen" do
      expect(build).to be_frozen
    end

    it "compares by value" do
      expect(build).to eq(build)
      expect(build.hash).to eq(build.hash)
    end

    it "differs from a finding with a different field" do
      expect(build).not_to eq(build(severity: :info))
    end
  end

  describe "the constant vocabulary" do
    it "freezes the symbolic location list" do
      expect(described_class::SYMBOLIC_LOCATIONS).to be_frozen
    end

    it "freezes the text field list" do
      expect(described_class::TEXT_FIELDS).to be_frozen
    end

    it "scopes its constants to Finding, not to LlmAudit" do
      expect(described_class.constants)
        .to contain_exactly(:CONFIG_LOCATION, :SYMBOLIC_LOCATIONS, :TEXT_FIELDS)
      expect(LlmAudit.constants).not_to include(:CONFIG_LOCATION, :SYMBOLIC_LOCATIONS, :TEXT_FIELDS)
    end
  end

  describe "location" do
    it "round-trips a file:line string unchanged" do
      expect(build(location: "app/services/summarizer.rb:42").location).to eq("app/services/summarizer.rb:42")
    end

    it "round-trips the symbolic :config location unchanged" do
      expect(build(location: described_class::CONFIG_LOCATION).location).to eq(:config)
    end

    it "reports a symbolic location as symbolic" do
      expect(build(location: described_class::CONFIG_LOCATION)).to be_symbolic_location
    end

    it "reports a file:line location as not symbolic" do
      expect(build).not_to be_symbolic_location
    end

    it "rejects a blank string" do
      expect { build(location: "   ") }
        .to raise_error(ArgumentError, /location must be a non-empty String or one of \[:config\]/)
    end

    it "rejects nil" do
      expect { build(location: nil) }.to raise_error(ArgumentError, /got nil/)
    end

    it "rejects an unrecognised symbol" do
      expect { build(location: :everywhere) }.to raise_error(ArgumentError, /got :everywhere/)
    end
  end

  describe ".valid_location?" do
    it "accepts the symbolic :config location" do
      expect(described_class.valid_location?(described_class::CONFIG_LOCATION)).to be true
    end

    it "accepts a non-empty file:line string" do
      expect(described_class.valid_location?("app/services/summarizer.rb:42")).to be true
    end

    it "rejects a blank string" do
      expect(described_class.valid_location?("  ")).to be false
    end

    it "rejects nil" do
      expect(described_class.valid_location?(nil)).to be false
    end
  end

  describe ".valid_text?" do
    it "accepts a non-empty String" do
      expect(described_class.valid_text?("LLM10:2025 Unbounded Consumption")).to be true
    end

    it "rejects a blank String" do
      expect(described_class.valid_text?("   ")).to be false
    end

    it "rejects nil" do
      expect(described_class.valid_text?(nil)).to be false
    end

    it "rejects a Symbol" do
      expect(described_class.valid_text?(:symbolic)).to be false
    end
  end

  describe "severity" do
    it "accepts every declarable level" do
      LlmAudit::Severity::LEVELS.each do |level|
        expect(build(severity: level).severity).to eq(level)
      end
    end

    it "rejects an unknown severity" do
      expect { build(severity: :critical) }
        .to raise_error(ArgumentError, /severity must be one of \[:error, :warning, :info, :undetermined\]/)
    end

    it "rejects the string form of a level" do
      expect { build(severity: "error") }.to raise_error(ArgumentError, /got "error"/)
    end
  end

  describe "check_id" do
    it "rejects a non-Symbol id" do
      expect { build(check_id: "request_timeout") }
        .to raise_error(ArgumentError, /check_id must be a Symbol, got "request_timeout"/)
    end
  end

  describe "the text fields" do
    LlmAudit::Finding::TEXT_FIELDS.each do |field|
      it "rejects a nil #{field}, so a report line cannot render blank" do
        expect { build(field => nil) }
          .to raise_error(ArgumentError, /#{field} must be a non-empty String, got nil/)
      end

      it "rejects a blank #{field}" do
        expect { build(field => "   ") }
          .to raise_error(ArgumentError, /#{field} must be a non-empty String, got "   "/)
      end

      it "rejects a non-String #{field}" do
        expect { build(field => :symbolic) }
          .to raise_error(ArgumentError, /#{field} must be a non-empty String, got :symbolic/)
      end
    end
  end

  describe "#with" do
    it "returns a copy carrying the replacement value" do
      expect(build.with(severity: :error).severity).to eq(:error)
    end

    it "re-validates the replacement value" do
      expect { build.with(severity: :critical) }.to raise_error(ArgumentError, /got :critical/)
    end

    it "re-validates a replacement text field" do
      expect { build.with(message: nil) }
        .to raise_error(ArgumentError, /message must be a non-empty String, got nil/)
    end

    it "leaves every other field untouched" do
      expect(build.with(severity: :error)).to eq(build(severity: :error))
    end

    it "returns the receiver itself when given no overrides" do
      finding = build

      expect(finding.with).to equal(finding)
    end

    it "rejects an unknown field" do
      expect { build.with(bogus: 1) }.to raise_error(ArgumentError, /unknown keyword: :bogus/)
    end

    it "returns a frozen copy" do
      expect(build.with(severity: :error)).to be_frozen
    end

    it "defines #with itself, because Data#with bypasses a custom initialize below Ruby 3.3" do
      expect(described_class.instance_method(:with).owner).to eq(described_class)
    end
  end

  describe ".undetermined" do
    subject(:finding) { described_class.undetermined(**attributes.except(:severity)) }

    it "carries the undetermined severity" do
      expect(finding.severity).to eq(LlmAudit::Severity::UNDETERMINED)
    end

    it "reports itself as undetermined" do
      expect(finding).to be_undetermined
    end

    it "takes no severity argument, so a check cannot mark an unreadable value as OK" do
      expect(described_class.method(:undetermined).parameters.map(&:last)).not_to include(:severity)
    end

    it "carries the remaining five fields unchanged" do
      expect(finding).to have_attributes(attributes.except(:severity))
    end

    it "does not itself stop #with re-severing an undetermined finding: the value object deliberately " \
       "carries the whole Severity::ALL vocabulary, and the narrowing to LEVELS lives above it, at " \
       "Checks::Base#finding for a selected severity and at Metadata for a declared one" do
      expect(finding.with(severity: :info)).not_to be_undetermined
    end
  end

  describe "#undetermined?" do
    it "is false for a finding carrying a declarable severity" do
      expect(build).not_to be_undetermined
    end
  end
end
