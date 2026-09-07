# frozen_string_literal: true

RSpec.describe LlmAudit::Formatters::Terminal do
  subject(:formatter) { described_class.new }

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
    LlmAudit::Finding.new(**attributes(**overrides))
  end

  describe "an empty collection" do
    it "returns the no-findings output rather than raising" do
      expect { formatter.call([]) }.not_to raise_error
    end

    it "returns the NO_FINDINGS constant" do
      expect(formatter.call([])).to eq(described_class::NO_FINDINGS)
    end

    it "reads llm_audit: no findings" do
      expect(formatter.call([])).to eq("llm_audit: no findings")
    end
  end

  describe "a nil collection" do
    it "raises rather than reporting a clean bill of health" do
      expect { formatter.call(nil) }.to raise_error(ArgumentError, /findings must be enumerable/)
    end
  end

  describe "a single finding" do
    it "renders the summary and all six fields" do
      expected = <<~REPORT.chomp
        llm_audit: 1 finding

        [WARNING] request_timeout: the client timeout is 300s
          location:    config/initializers/ruby_llm.rb:12
          remediation: Set a timeout below the web request budget.
          owasp:       LLM10:2025 Unbounded Consumption
      REPORT

      expect(formatter.call([build])).to eq(expected)
    end
  end

  describe "location rendering" do
    it "renders a file:line location verbatim" do
      expect(formatter.call([build(location: "app/services/summarizer.rb:42")]))
        .to include("  location:    app/services/summarizer.rb:42\n")
    end

    it "renders the symbolic :config location in parentheses" do
      expect(formatter.call([build(location: LlmAudit::Finding::CONFIG_LOCATION)]))
        .to include("  location:    (config)\n")
    end
  end

  describe "severity band" do
    it "renders each declarable level upcased" do
      LlmAudit::Severity::LEVELS.each do |level|
        expect(formatter.call([build(severity: level)])).to include("[#{level.to_s.upcase}] request_timeout:")
      end
    end

    it "renders an undetermined finding with the UNDETERMINED band" do
      finding = LlmAudit::Finding.undetermined(**attributes.except(:severity))

      expect(formatter.call([finding])).to include("[UNDETERMINED] request_timeout:")
    end
  end

  describe "the summary line" do
    it "is singular for one finding" do
      expect(formatter.call([build])).to start_with("llm_audit: 1 finding\n")
    end

    it "is plural for two findings" do
      expect(formatter.call([build, build(check_id: :missing_retries)])).to start_with("llm_audit: 2 findings\n")
    end
  end

  describe "the collection" do
    it "preserves input order" do
      findings = [build(check_id: :first), build(check_id: :second), build(check_id: :third)]

      expect(formatter.call(findings).scan(/^\[WARNING\] (\w+):/).flatten).to eq(%w[first second third])
    end

    it "separates findings with a blank line" do
      expect(formatter.call([build, build(check_id: :missing_retries)]))
        .to include("LLM10:2025 Unbounded Consumption\n\n[WARNING] missing_retries:")
    end

    it "accepts any Enumerable, not just an Array" do
      findings = [build].each

      expect(findings).not_to be_a(Array)
      expect(formatter.call(findings)).to eq(formatter.call([build]))
    end
  end

  describe "free text containing line breaks" do
    it "renders one severity band per finding, so a message cannot forge another" do
      output = formatter.call([build(message: "real\n\n[ERROR] fake_check: injected")])

      expect(output).to start_with("llm_audit: 1 finding\n")
      expect(output.scan(/^\[/).size).to eq(1)
    end

    it "renders one severity band per finding, so a check id cannot forge another" do
      output = formatter.call([build(check_id: :"fake\n\n[ERROR] injected_check: forged")])

      expect(output).to start_with("llm_audit: 1 finding\n")
      expect(output.scan(/^\[/).size).to eq(1)
    end

    it "collapses a line break in the check id" do
      expect(formatter.call([build(check_id: :"first\nsecond")]))
        .to include("[WARNING] first second: the client timeout is 300s\n")
    end

    it "collapses a line break in the message onto the finding's own line" do
      expect(formatter.call([build(message: "first\nsecond")]))
        .to include("[WARNING] request_timeout: first second\n")
    end

    it "collapses a line break in the remediation" do
      expect(formatter.call([build(remediation: "do this\nthen that")]))
        .to include("  remediation: do this then that\n")
    end

    it "collapses a line break in the location" do
      expect(formatter.call([build(location: "app/a.rb:1\napp/b.rb:2")]))
        .to include("  location:    app/a.rb:1 app/b.rb:2\n")
    end

    it "returns no trailing newline when the owasp reference ends with one" do
      expect(formatter.call([build(owasp_reference: "LLM10\n")])).not_to end_with("\n")
    end
  end

  describe "free text containing a control character" do
    it "strips an ANSI escape, so a message cannot repaint the line as a clean bill of health" do
      output = formatter.call([build(message: "clean\e[2K\rllm_audit: no findings")])

      expect(output).to include("[WARNING] request_timeout: clean [2K llm_audit: no findings\n")
      expect(output).not_to include("\e")
    end

    it "strips an ANSI escape from the check id, so it cannot repaint the line either" do
      output = formatter.call([build(check_id: :"a\e[2K\rllm_audit: no findings")])

      expect(output).to include("[WARNING] a [2K llm_audit: no findings: the client timeout is 300s\n")
      expect(output).not_to include("\e")
    end

    it "renders ASCII only even for a message carrying an escape sequence" do
      expect(formatter.call([build(message: "clean\e[2K\rmasked")])).to match(/\A[\x20-\x7E\n]*\z/)
    end

    it "strips a NUL, a DEL and a BEL from the message" do
      expect(formatter.call([build(message: "a\x00b\x7fc\ad")]))
        .to include("[WARNING] request_timeout: a b c d\n")
    end

    it "strips a control character from the remediation and the owasp reference too" do
      output = formatter.call([build(remediation: "do\e[2Kthis", owasp_reference: "LLM10\e[2K:2025")])

      expect(output).to include("  remediation: do [2Kthis\n")
      expect(output).to include("  owasp:       LLM10 [2K:2025")
    end

    it "leaves printable UTF-8 in the message intact" do
      expect(formatter.call([build(message: "café timeout 300s")]))
        .to include("[WARNING] request_timeout: café timeout 300s\n")
    end
  end

  describe "the formatter contract" do
    it "returns a String" do
      expect(formatter.call([build])).to be_a(String)
    end

    it "returns a String for an empty collection too" do
      expect(formatter.call([])).to be_a(String)
    end

    it "returns output with no trailing newline, so Doctor supplies it" do
      expect(formatter.call([build])).not_to end_with("\n")
      expect(formatter.call([])).not_to end_with("\n")
    end

    it "writes nothing to stdout" do
      expect { formatter.call([build]) }.not_to output.to_stdout
    end

    it "writes nothing to stdout for an empty collection" do
      expect { formatter.call([]) }.not_to output.to_stdout
    end

    it "takes no constructor arguments, so the collection cannot become constructor state" do
      expect(described_class.instance_method(:initialize).arity).to eq(0)
    end

    it "is stateless, so one instance can be reused across collections" do
      expect(formatter.call([build, build])).to start_with("llm_audit: 2 findings\n")
      expect(formatter.call([build])).to start_with("llm_audit: 1 finding\n")
      expect(formatter.call([])).to eq(described_class::NO_FINDINGS)
    end

    it "exposes a one-argument #call" do
      expect(described_class.instance_method(:call).arity).to eq(1)
    end

    it "renders ASCII only, with no ANSI escape sequences" do
      expect(formatter.call([build])).to match(/\A[\x20-\x7E\n]*\z/)
    end
  end
end
