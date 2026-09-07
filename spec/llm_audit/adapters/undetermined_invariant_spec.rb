# frozen_string_literal: true

require "ripper"

RSpec.describe "the undetermined invariant" do
  let(:lib_directory) { File.expand_path("../../../lib", __dir__) }
  let(:adapter_files) { Dir.glob(File.join(lib_directory, "llm_audit", "adapters", "**", "*.rb")) }
  let(:check_layer_file) { File.join(lib_directory, "llm_audit", "checks", "base.rb") }
  let(:prose_tokens) { %i[on_comment on_embdoc] }
  let(:upper_layer_name) { /\A(?:Severity|UNDETERMINED|undetermined|Finding|Checks|Doctor|Registry)\z/ }
  let(:offences) { offences_in(adapter_files) }

  def offences_in(paths)
    paths.flat_map { |path| offences_in_file(path) }
  end

  def offences_in_file(path)
    lines = File.readlines(path)
    offending = code_tokens(lines.join)
                .filter_map { |((number, _), _, token, _)| number if token.match?(upper_layer_name) }

    offending.uniq.map { |number| "#{path}:#{number}: #{lines[number - 1].strip}" }
  end

  def code_tokens(source)
    Ripper.lex(source).reject { |(_, type, _, _)| prose_tokens.include?(type) }
  end

  def token_texts(source)
    code_tokens(source).map { |(_, _, token, _)| token }
  end

  describe "the adapter sources" do
    it "are found by the scan, so a broken glob cannot pass vacuously" do
      expect(adapter_files).not_to be_empty
    end

    it "are scanned by something that does find these names in the check layer, so the scan is not inert" do
      expect(offences_in([check_layer_file])).not_to be_empty
    end

    it "name nothing from the layers above them, so an adapter cannot grade what it read" do
      expect(offences).to be_empty, <<~MESSAGE
        An adapter reports a Reading and a check turns it into a Finding: severity is chosen above the
        adapter, which is what keeps :undetermined reachable only through Checks::Base#undetermined. The
        reverse reach is watched too: an adapter that named Checks, Doctor or the Registry would bind the
        layer an M2 cop has to reuse to the run that doctor performs.
        Names from above found:
        #{offences.join("\n")}
      MESSAGE
    end

    it "keep their own determined vocabulary, which shares a word with the severity but not the meaning" do
      texts = token_texts("reading.determined? && Reading::DETERMINED_STATES.include?(reading.state)")

      expect(texts).to include("determined?", "DETERMINED_STATES")
      expect(texts.grep(upper_layer_name)).to be_empty
    end

    it "would be caught naming any one of them, in code or in a string, so neither form slips the scan" do
      %w[Severity UNDETERMINED undetermined Finding Checks Doctor Registry].each do |name|
        expect(token_texts("x = #{name}").grep(upper_layer_name)).to eq([name])
        expect(token_texts(%(x = "#{name}")).grep(upper_layer_name)).to eq([name])
      end
    end
  end

  describe "the bridge from a reading to a finding" do
    let(:config_class) { Data.define(:request_timeout, :max_retries) }
    let(:adapter) do
      live = config_class.new(request_timeout: 300, max_retries: 5)
      pristine = config_class.new(request_timeout: 300, max_retries: 3)
      adapter_class = Class.new(LlmAudit::Adapters::Base) do
        declare id: :bridge_client, gem_name: "bridge-client", client_constant: "BridgeClient",
                settings: { request_timeout: :request_timeout, max_retries: :max_retries }
      end
      adapter_class.define_method(:configuration) { live }
      adapter_class.define_method(:default_configuration) { pristine }
      adapter_class.new
    end
    let(:findings) { bridging_check(adapter.readings).new.call }

    before { stub_const("BridgeClient", Module.new) }

    def bridging_check(readings)
      Class.new(LlmAudit::Checks::Base) do
        declare id: :bridge_check, default_severity: :warning,
                owasp_reference: "LLM10:2025 Unbounded Consumption"

        define_method(:call) { readings.values.map { |reading| report(reading) } }

        define_method(:report) do |reading|
          text = { location: :config, message: "#{reading.setting} is #{reading.state}", remediation: "set it" }
          return undetermined(**text) if reading.undetermined?

          finding(**text)
        end
      end
    end

    it "hands the check a reading with a state and no severity, so the adapter grades nothing" do
      expect(adapter.readings.values.map(&:state)).to eq(%i[defaulted configured])
      expect(LlmAudit::Adapters::Reading.members).not_to include(:severity)
    end

    it "turns an undetermined reading into an undetermined finding rather than a passing one" do
      expect(findings.first).to be_undetermined
      expect(findings.first.severity).to eq(LlmAudit::Severity::UNDETERMINED)
    end

    it "turns a determined reading into a finding at the severity the check declared, not the adapter" do
      expect(findings.last).not_to be_undetermined
      expect(findings.last.severity).to eq(:warning)
    end

    it "reaches :undetermined only through the builder that takes no severity argument" do
      parameters = LlmAudit::Checks::Base.instance_method(:undetermined).parameters.map(&:last)

      expect(parameters).to eq(%i[location message remediation])
      expect(parameters).not_to include(:severity)
    end

    it "leaves an adapter no severity to declare: its whole vocabulary is disjoint from the severities" do
      expect(LlmAudit::Adapters::Reading::STATES & LlmAudit::Severity::ALL).to be_empty
    end
  end
end
