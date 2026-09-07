# frozen_string_literal: true

RSpec.describe LlmAudit::Checks::Base do
  def declared_check(id: :fixture_check, default_severity: :warning,
                     owasp_reference: "LLM01:2025 Prompt Injection")
    Class.new(described_class) do
      declare id: id, default_severity: default_severity, owasp_reference: owasp_reference
    end
  end

  describe "Metadata" do
    subject(:metadata) { described_class::Metadata }

    it "carries exactly the three declared fields" do
      expect(metadata.members).to eq(%i[id default_severity owasp_reference])
    end

    it "freezes what it builds" do
      expect(metadata.new(id: :x, default_severity: :info, owasp_reference: "ref")).to be_frozen
    end

    it "accepts every declarable level" do
      severities = LlmAudit::Severity::LEVELS.map do |level|
        metadata.new(id: :x, default_severity: level, owasp_reference: "ref").default_severity
      end

      expect(severities).to eq(LlmAudit::Severity::LEVELS)
    end

    it "refuses :undetermined, so no check can declare itself unreadable" do
      expect { metadata.new(id: :x, default_severity: :undetermined, owasp_reference: "ref") }
        .to raise_error(ArgumentError, /default_severity must be one of \[:error, :warning, :info\]/)
    end

    it "rejects a severity outside the vocabulary" do
      expect { metadata.new(id: :x, default_severity: :critical, owasp_reference: "ref") }
        .to raise_error(ArgumentError, /got :critical/)
    end

    it "rejects a non-Symbol id" do
      expect { metadata.new(id: "x", default_severity: :info, owasp_reference: "ref") }
        .to raise_error(ArgumentError, /id must be a Symbol, got "x"/)
    end

    it "requires the owasp reference" do
      expect { metadata.new(id: :x, default_severity: :info) }
        .to raise_error(ArgumentError, /missing keyword: :owasp_reference/)
    end

    it "rejects a nil owasp reference at the declaration point" do
      expect { metadata.new(id: :x, default_severity: :info, owasp_reference: nil) }
        .to raise_error(ArgumentError, /owasp_reference must be a non-empty String, got nil/)
    end

    it "rejects a blank owasp reference, which would be stamped onto every finding" do
      expect { metadata.new(id: :x, default_severity: :info, owasp_reference: "   ") }
        .to raise_error(ArgumentError, /owasp_reference must be a non-empty String/)
    end

    it "applies the same non-empty rule the Finding value object uses" do
      expect(LlmAudit::Finding.valid_text?("   ")).to be false

      allow(LlmAudit::Finding).to receive(:valid_text?).and_call_original
      expect { metadata.new(id: :x, default_severity: :info, owasp_reference: "   ") }
        .to raise_error(ArgumentError)
      expect(LlmAudit::Finding).to have_received(:valid_text?).with("   ")
    end
  end

  describe ".declare" do
    it "exposes the declaration as metadata on the class" do
      expect(declared_check.metadata)
        .to eq(described_class::Metadata.new(id: :fixture_check, default_severity: :warning,
                                             owasp_reference: "LLM01:2025 Prompt Injection"))
    end

    it "reads back through the class-level accessors" do
      check = declared_check

      expect([check.id, check.default_severity, check.owasp_reference])
        .to eq([:fixture_check, :warning, "LLM01:2025 Prompt Injection"])
    end

    it "reads metadata without instantiating the check" do
      check = declared_check
      expect(check).not_to receive(:new)

      expect([check.metadata.id, check.id, check.default_severity, check.owasp_reference])
        .to eq([:fixture_check, :fixture_check, :warning, "LLM01:2025 Prompt Injection"])
    end

    it "refuses a declaration a check may not make about itself" do
      expect { declared_check(default_severity: :undetermined) }
        .to raise_error(ArgumentError, /default_severity must be one of/)
    end

    it "is private, so a registered check's id cannot be reassigned from outside its own body" do
      check = declared_check

      expect { check.declare(id: :hijacked, default_severity: :error, owasp_reference: "ref") }
        .to raise_error(NoMethodError, /private method/)
    end

    it "refuses a second declaration, which would desync the check from its registry key" do
      check = declared_check

      expect { check.send(:declare, id: :hijacked, default_severity: :error, owasp_reference: "ref") }
        .to raise_error(LlmAudit::Error, /#{Regexp.escape(check.metadata.inspect)}/)
    end

    it "keeps the first declaration when a second one is refused" do
      check = declared_check

      expect { check.send(:declare, id: :hijacked, default_severity: :error, owasp_reference: "ref") }
        .to raise_error(LlmAudit::Error, /already declared its metadata/)
      expect(check.id).to eq(:fixture_check)
    end
  end

  describe ".metadata when nothing was declared" do
    it "raises an LlmAudit::Error rather than returning nil" do
      expect { Class.new(described_class).metadata }
        .to raise_error(LlmAudit::Error, /did not declare its metadata/)
    end

    it "names the offending class with inspect, so an anonymous class still reads back" do
      check = Class.new(described_class)

      expect { check.metadata }.to raise_error(LlmAudit::Error, /#{Regexp.escape(check.inspect)}/)
    end

    it "raises from every class-level accessor" do
      check = Class.new(described_class)

      expect { check.id }.to raise_error(LlmAudit::Error)
      expect { check.default_severity }.to raise_error(LlmAudit::Error)
      expect { check.owasp_reference }.to raise_error(LlmAudit::Error)
    end

    it "does not inherit a parent's metadata, so a subclass must declare its own" do
      subclass = Class.new(declared_check)

      expect { subclass.metadata }.to raise_error(LlmAudit::Error, /did not declare its metadata/)
    end
  end

  describe "#call" do
    it "raises NotImplementedError naming the class that failed to implement it" do
      check = declared_check

      expect { check.new.call }
        .to raise_error(NotImplementedError, /#{Regexp.escape(check.inspect)} must implement #call/)
    end
  end

  describe "#finding" do
    subject(:check) { declared_check.new }

    it "is private, so only the check itself can build its findings" do
      expect(described_class.private_instance_methods(false)).to include(:finding)
    end

    it "cannot be called from outside the check" do
      expect { check.finding(location: :config, message: "m", remediation: "r") }
        .to raise_error(NoMethodError, /private method/)
    end

    it "stamps the check's own id and owasp reference" do
      finding = check.send(:finding, location: "config/initializers/llm.rb:4", message: "m", remediation: "r")

      expect([finding.check_id, finding.owasp_reference])
        .to eq([:fixture_check, "LLM01:2025 Prompt Injection"])
    end

    it "defaults the severity to the declared default" do
      finding = check.send(:finding, location: :config, message: "m", remediation: "r")

      expect(finding.severity).to eq(:warning)
    end

    it "accepts an explicit severity for a check that grades its own findings" do
      finding = check.send(:finding, location: :config, message: "m", remediation: "r", severity: :error)

      expect(finding.severity).to eq(:error)
    end

    it "refuses :undetermined, so the confident builder cannot bypass #undetermined" do
      expect { check.send(:finding, location: :config, message: "m", remediation: "r", severity: :undetermined) }
        .to raise_error(ArgumentError, /use #undetermined for a value that could not be read/)
    end

    it "refuses a severity outside the declarable vocabulary" do
      expect { check.send(:finding, location: :config, message: "m", remediation: "r", severity: :critical) }
        .to raise_error(ArgumentError, /severity must be one of \[:error, :warning, :info\], got :critical/)
    end

    it "has no parameter through which a check could attribute the finding elsewhere" do
      params = described_class.instance_method(:finding).parameters.map(&:last)

      expect(params & %i[check_id owasp_reference]).to be_empty
    end

    it "passes location, message and remediation through unchanged" do
      finding = check.send(:finding, location: "app/models/chat.rb:12", message: "no timeout",
                                     remediation: "set one")

      expect([finding.location, finding.message, finding.remediation])
        .to eq(["app/models/chat.rb:12", "no timeout", "set one"])
    end

    it "returns a Finding" do
      expect(check.send(:finding, location: :config, message: "m", remediation: "r"))
        .to be_a(LlmAudit::Finding)
    end
  end

  describe "#undetermined" do
    subject(:check) { declared_check.new }

    it "is private, so only the check itself can build its findings" do
      expect(described_class.private_instance_methods(false)).to include(:undetermined)
    end

    it "cannot be called from outside the check" do
      expect { check.undetermined(location: :config, message: "m", remediation: "r") }
        .to raise_error(NoMethodError, /private method/)
    end

    it "carries the undetermined severity rather than the declared default" do
      finding = check.send(:undetermined, location: :config, message: "m", remediation: "r")

      expect([finding.severity, finding.undetermined?]).to eq([:undetermined, true])
    end

    it "stamps the check's own id and owasp reference" do
      finding = check.send(:undetermined, location: :config, message: "m", remediation: "r")

      expect([finding.check_id, finding.owasp_reference])
        .to eq([:fixture_check, "LLM01:2025 Prompt Injection"])
    end

    it "passes location, message and remediation through unchanged" do
      finding = check.send(:undetermined, location: "config/initializers/llm.rb:4",
                                          message: "client not loaded", remediation: "install it")

      expect([finding.location, finding.message, finding.remediation])
        .to eq(["config/initializers/llm.rb:4", "client not loaded", "install it"])
    end

    it "has no parameter through which a check could attribute the finding elsewhere" do
      params = described_class.instance_method(:undetermined).parameters.map(&:last)

      expect(params & %i[check_id owasp_reference]).to be_empty
    end
  end
end
