# frozen_string_literal: true

RSpec.describe LlmAudit::Checks::MaxOutputTokens do
  # The fixture shape of spec/llm_audit/checks/max_retries_spec.rb: every adapter is a real Adapters::Base
  # subclass over a fabricated configuration, no client gem is required from this file, and every helper hands
  # back a CLASS because that is what Checks::Base#initialize takes. The configuration carries one member,
  # since the other two canonical settings map to nil and Base#reading never touches the object for them.
  let(:config_class) { Data.define(:max_output_tokens) }
  let(:canonical_settings) { { request_timeout: nil, max_retries: nil, max_output_tokens: :max_output_tokens } }
  # 1024 and not 4096, so the threshold itself stays buildable as a :configured value: live 4096 over pristine
  # 1024 reads as :configured 4096, which is the boundary the strict > is specced against below.
  let(:client_default) { 1024 }

  def cap_config(cap) = config_class.new(max_output_tokens: cap)

  def adapter_class_over(live, pristine, settings: canonical_settings, gem_name: "fabricated-client",
                         client_constant: "FabricatedClient")
    adapter_class = Class.new(LlmAudit::Adapters::Base) do
      declare id: :fabricated, gem_name: gem_name, client_constant: client_constant, settings: settings
    end
    adapter_class.define_method(:configuration) { live }
    adapter_class.define_method(:default_configuration) { pristine }
    adapter_class
  end

  def loaded(adapter_class)
    stub_const(adapter_class.client_constant, Module.new)
    adapter_class
  end

  def configured_adapter_class(value, **options)
    raise ArgumentError, "#{value} is the client default and reads as :defaulted" if value == client_default

    loaded(adapter_class_over(cap_config(value), cap_config(client_default), **options))
  end

  def defaulted_adapter_class(value) = loaded(adapter_class_over(cap_config(value), cap_config(value)))
  def unreadable_adapter_class = loaded(adapter_class_over(Object.new, Object.new))

  def unsupported_adapter_class
    loaded(adapter_class_over(cap_config(8192), cap_config(client_default),
                              settings: { request_timeout: nil, max_retries: nil, max_output_tokens: nil }))
  end

  def absent_adapter_class
    adapter_class_over(cap_config(8192), cap_config(client_default), client_constant: "UnloadedClient")
  end

  def findings_for(*adapters, **options) = described_class.new(adapters: adapters, **options).call

  describe "the check contract" do
    it "is a check, so the registry can run it the one way it runs every other" do
      expect(described_class.ancestors).to include(LlmAudit::Checks::Base)
    end

    it "declares its id, severity and reference without being instantiated" do
      expect(described_class).not_to receive(:new)

      expect([described_class.id, described_class.default_severity, described_class.owasp_reference])
        .to eq([:max_output_tokens, :warning, "LLM06:2026 Unbounded Consumption"])
    end

    it "is reachable through the gem-wide registry, which is the list Doctor runs" do
      expect(LlmAudit.registry.fetch(:max_output_tokens)).to eq(described_class)
    end

    it "grades itself :warning, a declarable level" do
      expect(LlmAudit::Severity.declarable?(described_class.default_severity)).to be true
    end
  end

  # AC8. No listed M1 adapter produces a :configured or :defaulted cap - ruby_llm has no client-wide one to
  # read - so the comparison examples here are the only reach of the graded path until a client with a
  # global cap, or the M2 cop reading a call site, hands one in. What ruby_llm does reach is the last example:
  # the threshold is still the ceiling the not-applicable remediation asks for on every call.
  describe "the threshold" do
    it "ships 4096 tokens, the cap ruby_llm's own Anthropic provider falls back to when a request states none" do
      expect(described_class::DEFAULT_THRESHOLD_TOKENS).to eq(4096)
    end

    it "takes it as a defaulted keyword argument, so Doctor still builds this check with no arguments" do
      expect(described_class.instance_method(:initialize).parameters).to include(%i[key threshold])
      expect { described_class.new }.not_to raise_error
    end

    it "fires above the threshold and not at it, sparing an app that deliberately chose the limit" do
      expect(findings_for(configured_adapter_class(4096))).to be_empty
      expect(findings_for(configured_adapter_class(4097)).map(&:severity)).to eq([:warning])
    end

    it "compares against the injected threshold, so the comparison site names no literal" do
      expect(findings_for(configured_adapter_class(2048), threshold: 2048)).to be_empty
      expect(findings_for(configured_adapter_class(2049), threshold: 2048).map(&:severity)).to eq([:warning])
    end

    it "renders the threshold it graded against, so the number reported is the number compared" do
      finding = findings_for(configured_adapter_class(4096), threshold: 2048).fetch(0)

      expect(finding.severity).to eq(:warning)
      expect(finding.message).to include("over the 2048 tokens", "[4096/2048]")
      expect(finding.remediation).to include("at or below 2048 tokens", "config.max_output_tokens = 2048")
    end

    it "is visible on a client with no cap of its own, as the ceiling to give every call" do
      remediation = findings_for(unsupported_adapter_class, threshold: 2048).fetch(0).remediation

      expect(remediation).to include("at or below 2048 tokens")
      expect(remediation).not_to include("4096")
    end
  end

  describe "a configured reading" do
    subject(:finding) { findings_for(configured_adapter_class(8192)).fetch(0) }

    it "warns over the threshold, naming both the value read and the limit it broke" do
      expect(finding.severity).to eq(:warning)
      expect(finding.message).to include("an output-token cap of 8192", "[8192/4096]")
    end

    it "says what each token costs, since every one is billed and takes time to generate" do
      expect(finding.message).to include("billed", "what a single response can cost")
    end

    it "reports it at the symbolic config location, carrying the check's own id and reference" do
      expect(finding.location).to eq(LlmAudit::Finding::CONFIG_LOCATION)
      expect(finding).to be_symbolic_location
      expect([finding.check_id, finding.owasp_reference])
        .to eq([:max_output_tokens, "LLM06:2026 Unbounded Consumption"])
    end

    it "puts the literal configuration line in the remediation, so the fix is copied rather than inferred" do
      expect(finding.remediation)
        .to include("`FabricatedClient.configure { |config| config.max_output_tokens = 4096 }`",
                    "config/initializers/fabricated-client.rb")
    end

    it "sends a call that genuinely needs more to raise its own cap, rather than the cap on every call" do
      expect(finding.remediation).to include("raise the cap at that call and not for every call")
    end

    it "reports nothing at all inside the limit: a value the app chose and can defend" do
      expect(findings_for(configured_adapter_class(2048))).to eq([])
    end

    it "accepts a Float, rendering it as written" do
      message = findings_for(configured_adapter_class(8192.5)).fetch(0).message

      expect(message).to include("8192.5", "[8192.5/4096]")
    end

    it "renders a Rational as the number it is, so no notation of its own reaches the report" do
      message = findings_for(configured_adapter_class(Rational(16_385, 2))).fetch(0).message

      expect(message).to include("8192.5", "[8192.5/4096]")
      expect(message).not_to include("16385/2")
    end
  end

  describe "a configured nil" do
    subject(:finding) { findings_for(configured_adapter_class(nil)).fetch(0) }

    it "warns that the app chose no cap, so what bounds a response is the model's ceiling or nothing" do
      expect(finding.severity).to eq(:warning)
      expect(finding.message).to include("no output-token cap", "model's own ceiling, or nothing")
      expect(finding.message).not_to include("[")
    end

    it "does not raise on the comparison, which `nil > 4096` would" do
      expect { nil > 4096 }.to raise_error(NoMethodError)
      expect { findings_for(configured_adapter_class(nil)) }.not_to raise_error
    end

    it "asks for a cap rather than a smaller one, there being no value here to lower" do
      expect(finding.remediation)
        .to include("Give the client a cap of its own, at or below 4096 tokens",
                    "`FabricatedClient.configure { |config| config.max_output_tokens = 4096 }`")
    end
  end

  # The divergence from the retry table: a zero or negative retry count is a bounded one, but a cap of zero
  # tokens is a response of no tokens, which every provider refuses and which bounds nothing.
  describe "a value that is not a cap" do
    it "grades each one an error, since no cap the app wrote down is in effect on any of them" do
      unusable = [0, -5, "8192", Float::NAN, Float::INFINITY, Complex(1, 1)]
      severities = unusable.map { |value| findings_for(configured_adapter_class(value)).map(&:severity) }

      expect(severities).to eq([[:error], [:error], [:error], [:error], [:error], [:error]])
    end

    it "puts zero and a negative count here rather than inside the limit, unlike the retry check" do
      zero = findings_for(configured_adapter_class(0)).fetch(0)
      negative = findings_for(configured_adapter_class(-5)).fetch(0)

      expect([zero.severity, negative.severity]).to eq(%i[error error])
      expect(zero.message).to include("configured with 0 as its output-token cap")
      expect(negative.message).to include("configured with -5 as its output-token cap")
      expect(zero.remediation).to include("Set a positive whole number of tokens, at or below 4096")
    end

    it "puts an infinite cap here rather than beside nil, and still measures nothing from it" do
      infinite = findings_for(configured_adapter_class(Float::INFINITY)).fetch(0)

      expect(infinite.message).to include("a Float rather than a positive count of tokens")
      expect(infinite.message).not_to include("Infinity", "no output-token cap")
    end

    it "describes a non-numeric value by its class and never echoes it into a report" do
      finding = findings_for(configured_adapter_class("8192")).fetch(0)

      expect(finding.message).to include("a String rather than a positive count of tokens")
      expect([finding.message, finding.remediation].join("\n")).not_to include("8192")
    end

    it "describes a Complex by its class rather than raising on a comparison it cannot make" do
      expect { Complex(1, 1) > 4096 }.to raise_error(NoMethodError)

      finding = findings_for(configured_adapter_class(Complex(1, 1))).fetch(0)

      expect(finding.severity).to eq(:error)
      expect(finding.message).to include("a Complex rather than a positive count of tokens")
      expect(finding.message).not_to include("1+1i")
    end

    it "asks for a positive whole number, with the literal line to set it" do
      finding = findings_for(configured_adapter_class("8192")).fetch(0)

      expect(finding.remediation)
        .to include("Set a positive whole number of tokens, at or below 4096",
                    "`FabricatedClient.configure { |config| config.max_output_tokens = 4096 }`")
    end

    # The description of the value already says it is not a positive count; the verdict clause that follows
    # must not say it again, on either provenance.
    it "says once that the value is not a positive count, whichever provenance renders it" do
      chosen = findings_for(configured_adapter_class("8192")).fetch(0).message
      inherited = findings_for(defaulted_adapter_class("8192")).fetch(0).message

      expect(chosen).to include("positive count of tokens as its output-token cap, so what the client makes of it")
      expect(inherited).to include("cannot be shown to have chosen, so what the client makes of it")
      expect([chosen.scan("positive count of tokens").size, inherited.scan("positive count of tokens").size])
        .to eq([1, 1])
    end
  end

  describe "a defaulted reading" do
    subject(:finding) { findings_for(defaulted_adapter_class(8192)).fetch(0) }

    it "attributes the value to the client and never to a choice the app made" do
      expect(finding.message).to include("the client's own default", "cannot be shown to have chosen")
      expect(finding.message).not_to include("is configured with")
    end

    it "warns when the inherited value is over the threshold, naming both numbers" do
      expect(finding.severity).to eq(:warning)
      expect(finding.message).to include("[8192/4096]")
    end

    it "does not fall silent inside the limit, since a value nobody chose can move on a bundle update" do
      inside = findings_for(defaulted_adapter_class(1024))

      expect(inside.map(&:severity)).to eq([:info])
      expect(inside.fetch(0).message).to include("[1024/4096]")
      expect(inside.fetch(0).remediation)
        .to include("Write the value down", "`FabricatedClient.configure { |config| config.max_output_tokens = 1024 }`")
    end

    # The G40 guard. A :defaulted reading hard-sets value to nil and carries its number in default; a check
    # that read the wrong field on this branch would hand nil to classify, which grades it :unset and renders
    # a client running happily on its own default as having no cap at all - a wrong verdict rather than a
    # crash, and one a :defaulted fixture built the obvious way cannot tell from the right one. Both halves
    # are asserted: the number that should be in the message, and the unset text that should not.
    it "reads the default through the reading's effective value, so a usable default is never reported as unset" do
      adapter_class = defaulted_adapter_class(1024)
      reading = adapter_class.new.reading(:max_output_tokens)
      message = findings_for(adapter_class).fetch(0).message

      expect([reading.state, reading.value, reading.default, reading.effective]).to eq([:defaulted, nil, 1024, 1024])
      expect(message).to include("1024")
      expect(message).not_to include("no output-token cap")
    end

    it "warns on a client whose own default is no cap, still without attributing it to the app" do
      unset = findings_for(defaulted_adapter_class(nil)).fetch(0)

      expect(unset.severity).to eq(:warning)
      expect(unset.message).to include("own default is no output-token cap", "cannot be shown to have chosen")
    end

    it "grades a default that is not a cap an error too, still without blaming the app for it" do
      unusable = findings_for(defaulted_adapter_class("8192")).fetch(0)

      expect(unusable.severity).to eq(:error)
      expect(unusable.message)
        .to include("a String rather than a positive count of tokens", "cannot be shown to have chosen")
      expect(unusable.message).not_to include("8192")
    end
  end

  # AC7: a client that ships no global cap leaves every call uncapped unless the call says otherwise, and a
  # per-call cap is written at a call site this audit cannot see. Anthropic's API refuses a request with no
  # cap at all, so a client that ships none is either failing those calls or capping them out of view -
  # a finding on its own, at the check's declared severity and never the :info its siblings give this state.
  describe "an unsupported reading" do
    subject(:finding) { findings_for(unsupported_adapter_class).fetch(0) }

    it "reports it at the check's own severity, the one the declaration names" do
      expect(finding.severity).to eq(described_class.default_severity)
      expect(finding.severity).to eq(:warning)
    end

    it "says that nothing this app configured bounds a response, and that the cap it cannot see is per call" do
      expect(finding.message).to include("ships no global output-token cap", "Anthropic",
                                         "neither is visible to this audit")
    end

    it "is not undetermined, since not applicable and unreadable are different claims" do
      expect(finding).not_to be_undetermined
      expect(finding.undetermined?).to be false
    end

    it "sends the fix to every call site, there being nothing on the client to set" do
      expect(finding.remediation).to include("Nothing to set on FabricatedClient globally",
                                             "`max_tokens`-style cap on every call", "at or below 4096 tokens")
    end

    it "is a finding and not silence, which is AC7's whole point" do
      expect(findings_for(unsupported_adapter_class).size).to eq(1)
    end

    # The same adapter, read by all three checks: it maps every canonical setting to nil, so each reads
    # :unsupported, and the two siblings grade that :info - a client with no timeout or no retries is
    # bounded from outside or bounded already. A client with no cap is neither.
    it "differs from its siblings, which grade the same state :info, since an uncapped response has a cost" do
      adapter_class = unsupported_adapter_class
      family = [LlmAudit::Checks::RequestTimeout, LlmAudit::Checks::MaxRetries, described_class]
      bands = family.to_h { |check| [check.id, check.new(adapters: [adapter_class]).call.map(&:severity)] }

      expect(bands).to eq(request_timeout: [:info], max_retries: [:info], max_output_tokens: [:warning])
    end
  end

  describe "an absent reading" do
    it "reports undetermined, naming the client that is not loaded rather than passing it" do
      finding = findings_for(absent_adapter_class).fetch(0)

      expect(Object.const_defined?("UnloadedClient", false)).to be false
      expect(finding).to be_undetermined
      expect(finding.message).to include("is not loaded in this process")
    end

    it "reads differently from a client that is loaded but unreadable, which is a different claim" do
      not_loaded = findings_for(absent_adapter_class).fetch(0)
      not_read = findings_for(unreadable_adapter_class).fetch(0)

      expect([not_loaded.severity, not_read.severity]).to eq(%i[undetermined undetermined])
      expect(not_loaded.message).not_to eq(not_read.message)
    end

    it "sends each to its own fix, since a client to boot and a renamed accessor are different problems" do
      not_loaded = findings_for(absent_adapter_class).fetch(0)
      not_read = findings_for(unreadable_adapter_class).fetch(0)

      expect(not_loaded.remediation).not_to eq(not_read.remediation)
      expect(not_loaded.remediation).to include("`rails llm_audit:doctor` boots the host app first")
      expect(not_read.remediation).to include("still exposes an output-token cap")
    end
  end

  describe "an unreadable reading" do
    subject(:finding) { findings_for(unreadable_adapter_class).fetch(0) }

    it "reports it through the builder that takes no severity, so no check could have graded it" do
      expect([finding.severity, finding.undetermined?]).to eq([LlmAudit::Severity::UNDETERMINED, true])
      expect(LlmAudit::Severity.declarable?(finding.severity)).to be false
    end

    it "reports no number, having read none" do
      expect(finding.message).to include("could not be read")
      expect(finding.message).not_to match(/\d/)
    end
  end

  describe "every state the adapter layer can report" do
    let(:fixtures) do
      { configured: -> { configured_adapter_class(8192) }, defaulted: -> { defaulted_adapter_class(8192) },
        unsupported: -> { unsupported_adapter_class }, absent: -> { absent_adapter_class },
        unreadable: -> { unreadable_adapter_class } }
    end

    it "has a fixture for each of them, so the grading below cannot skip one it was never handed" do
      expect(fixtures.keys).to eq(LlmAudit::Adapters::Reading::STATES)
    end

    it "grades each through its own branch, at the severity that state's claim deserves" do
      graded = LlmAudit::Adapters::Reading::STATES.to_h do |state|
        adapter_class = fixtures.fetch(state).call
        [state, [adapter_class.new.reading(:max_output_tokens).state, findings_for(adapter_class).map(&:severity)]]
      end

      expect(graded).to eq(configured: [:configured, [:warning]], defaulted: [:defaulted, [:warning]],
                           unsupported: [:unsupported, [:warning]], absent: [:absent, [:undetermined]],
                           unreadable: [:unreadable, [:undetermined]])
    end

    it "raises for a state it was never taught, which Doctor degrades rather than losing the run" do
      speculative = Data.define(:state, :value, :default).new(state: :speculative, value: 8192, default: nil)
      adapter_class = configured_adapter_class(8192)
      adapter_class.define_method(:reading) { |_setting| speculative }

      expect { findings_for(adapter_class) }
        .to raise_error(LlmAudit::Error, /has no verdict for a :speculative reading/)
    end
  end

  describe "a value that is really a credential" do
    let(:leaky) do
      stub_const("LeakyConfiguration", Class.new do
        def to_s = "sk-leaked-key"
        def inspect = %(#<LeakyConfiguration api_key="sk-leaked-key">)
      end)
    end

    it "never reaches the report, in either the message or the remediation" do
      expect([leaky.new.to_s, leaky.new.inspect]).to all(include("sk-leaked-key"))
      findings = [configured_adapter_class("sk-leaked-key"), configured_adapter_class(leaky.new)]
                 .flat_map { |adapter_class| findings_for(adapter_class) }

      expect(findings.map(&:severity)).to eq(%i[error error])
      expect(findings.flat_map { |f| [f.message, f.remediation] }.join("\n")).not_to include("sk-leaked")
    end
  end

  describe "the run as a whole" do
    it "reports once per adapter, since each client carries its own configuration" do
      first = configured_adapter_class(8192)
      second = configured_adapter_class(16_384, gem_name: "second-client", client_constant: "SecondClient")

      messages = findings_for(first, second).map(&:message)

      expect(messages.size).to eq(2)
      expect(messages.first).to include("fabricated-client", "[8192/4096]")
      expect(messages.last).to include("second-client", "[16384/4096]")
    end

    # One finding per adapter holds because ruby_llm reads :unsupported in a process that loaded it, which is
    # graded :warning and never silent, or :absent in one that did not, which is undetermined; the
    # chosen/within branch is the only silent one and no listed client can reach it at all.
    it "reads the gem-wide manifest when nothing is injected, one finding per listed adapter" do
      expect(described_class.new.call.map(&:check_id)).to eq([:max_output_tokens] * LlmAudit.adapters.size)
    end

    it "reports the same findings twice over, so a run tells the same story as the one before it" do
      expect(described_class.new.call).to eq(described_class.new.call)
    end
  end
end
