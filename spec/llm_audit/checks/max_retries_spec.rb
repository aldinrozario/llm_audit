# frozen_string_literal: true

RSpec.describe LlmAudit::Checks::MaxRetries do
  # The fixture shape of spec/llm_audit/checks/request_timeout_spec.rb: every adapter is a real Adapters::Base
  # subclass over a fabricated configuration, no client gem is required from this file, and every helper hands
  # back a CLASS because that is what Checks::Base#initialize takes. The configuration carries one member,
  # since the other two canonical settings map to nil and Base#reading never touches the object for them.
  let(:config_class) { Data.define(:max_retries) }
  let(:canonical_settings) { { request_timeout: nil, max_retries: :max_retries, max_output_tokens: nil } }
  # 2 and not 3, so the threshold itself stays buildable as a :configured value: live 3 over pristine 2 reads
  # as :configured 3, which is the boundary the strict > is specced against below.
  let(:client_default) { 2 }

  def retries_config(retries) = config_class.new(max_retries: retries)

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

    loaded(adapter_class_over(retries_config(value), retries_config(client_default), **options))
  end

  def defaulted_adapter_class(value) = loaded(adapter_class_over(retries_config(value), retries_config(value)))
  def unreadable_adapter_class = loaded(adapter_class_over(Object.new, Object.new))

  def unsupported_adapter_class
    loaded(adapter_class_over(retries_config(10), retries_config(client_default),
                              settings: { request_timeout: nil, max_retries: nil, max_output_tokens: nil }))
  end

  def absent_adapter_class
    adapter_class_over(retries_config(10), retries_config(client_default), client_constant: "UnloadedClient")
  end

  def findings_for(*adapters, **options) = described_class.new(adapters: adapters, **options).call

  describe "the check contract" do
    it "is a check, so the registry can run it the one way it runs every other" do
      expect(described_class.ancestors).to include(LlmAudit::Checks::Base)
    end

    it "declares its id, severity and reference without being instantiated" do
      expect(described_class).not_to receive(:new)

      expect([described_class.id, described_class.default_severity, described_class.owasp_reference])
        .to eq([:max_retries, :warning, "LLM06:2026 Unbounded Consumption"])
    end

    it "is reachable through the gem-wide registry, which is the list Doctor runs" do
      expect(LlmAudit.registry.fetch(:max_retries)).to eq(described_class)
    end

    it "grades itself :warning, a declarable level" do
      expect(LlmAudit::Severity.declarable?(described_class.default_severity)).to be true
    end
  end

  describe "the threshold" do
    it "ships 3 retries, the widest default any blessed client ships as its own" do
      expect(described_class::DEFAULT_THRESHOLD_RETRIES).to eq(3)
    end

    it "takes it as a defaulted keyword argument, so Doctor still builds this check with no arguments" do
      expect(described_class.instance_method(:initialize).parameters).to include(%i[key threshold])
      expect { described_class.new }.not_to raise_error
    end

    it "fires above the threshold and not at it, sparing an app that deliberately chose the limit" do
      expect(findings_for(configured_adapter_class(3))).to be_empty
      expect(findings_for(configured_adapter_class(4)).map(&:severity)).to eq([:warning])
    end

    it "compares against the injected threshold, so the comparison site names no literal" do
      expect(findings_for(configured_adapter_class(5), threshold: 5)).to be_empty
      expect(findings_for(configured_adapter_class(6), threshold: 5).map(&:severity)).to eq([:warning])
    end

    it "renders the threshold it graded against, so the number reported is the number compared" do
      finding = findings_for(configured_adapter_class(10), threshold: 4).fetch(0)

      expect(finding.message).to include("over the 4 retries", "[10/4]")
      expect(finding.remediation).to include("at or below 4", "config.max_retries = 4")
    end
  end

  describe "a configured reading" do
    subject(:finding) { findings_for(configured_adapter_class(10)).fetch(0) }

    it "warns over the threshold, naming both the value read and the limit it broke" do
      expect(finding.severity).to eq(:warning)
      expect(finding.message).to include("a retry count of 10", "[10/3]")
    end

    it "says what each retry costs, since every one repeats the whole attempt with its timeout" do
      expect(finding.message).to include("multiplied by one more than this count")
      expect(finding.message).not_to match(/never retr|unbounded/)
    end

    it "reports it at the symbolic config location, carrying the check's own id and reference" do
      expect(finding.location).to eq(LlmAudit::Finding::CONFIG_LOCATION)
      expect(finding).to be_symbolic_location
      expect([finding.check_id, finding.owasp_reference]).to eq([:max_retries, "LLM06:2026 Unbounded Consumption"])
    end

    it "puts the literal configuration line in the remediation, so the fix is copied rather than inferred" do
      expect(finding.remediation)
        .to include("`FabricatedClient.configure { |config| config.max_retries = 3 }`",
                    "config/initializers/fabricated-client.rb", "transient failures")
    end

    # There is no value of this setting that means "retry forever": the retry middleware counts down from
    # whatever number it is given. A large count is the only way to write unbounded, so the threshold
    # comparison is the one place it can be caught, and it is.
    it "catches a large count, the only unbounded this setting can express, through the threshold" do
      findings = findings_for(configured_adapter_class(1_000_000_000))

      expect(findings.map(&:severity)).to eq([:warning])
      expect(findings.fetch(0).message).to include("[1000000000/3]")
    end

    it "reports nothing at all inside the limit: a value the app chose and can defend" do
      expect(findings_for(configured_adapter_class(1))).to eq([])
    end

    it "accepts a Float, rendering it as written" do
      message = findings_for(configured_adapter_class(3.5)).fetch(0).message

      expect(message).to include("3.5", "[3.5/3]")
    end

    it "renders a Rational as the number it is, so no notation of its own reaches the report" do
      message = findings_for(configured_adapter_class(Rational(7, 2))).fetch(0).message

      expect(message).to include("3.5", "[3.5/3]")
      expect(message).not_to include("7/2")
    end
  end

  # The divergence from the timeout's table: a 0s timeout is a value no request can use, but a zero or
  # negative retry count is a bounded one - the client retries nothing on either.
  describe "a bounded count" do
    it "is silent on zero and on a negative count when the app chose them, since either can be defended" do
      expect(findings_for(configured_adapter_class(0))).to eq([])
      expect(findings_for(configured_adapter_class(-1))).to eq([])
    end

    it "still reports an inherited zero, because a default nobody chose can move on a bundle update" do
      inherited = findings_for(defaulted_adapter_class(0))

      expect(inherited.map(&:severity)).to eq([:info])
      expect(inherited.fetch(0).message).to include("0", "[0/3]")
    end
  end

  # nil is what the Faraday-backed clients hand to the retry middleware, which substitutes a default of its
  # own: not zero, not unbounded, and not a number this check can quote.
  describe "a configured nil" do
    subject(:finding) { findings_for(configured_adapter_class(nil)).fetch(0) }

    it "warns that the app chose no count, without calling it zero, unbounded, or a measurement" do
      expect(finding.severity).to eq(:warning)
      expect(finding.message).to include("no retry count of its own", "HTTP stack applies")
      expect(finding.message).not_to match(/never retr|no retries|unbounded|\[/)
    end

    it "does not raise on the comparison, which `nil > 3` would" do
      expect { nil > 3 }.to raise_error(NoMethodError)
      expect { findings_for(configured_adapter_class(nil)) }.not_to raise_error
    end

    it "asks for a count rather than a smaller one, there being no value here to lower" do
      expect(finding.remediation)
        .to include("Give the client a retry count of its own, at or below 3",
                    "`FabricatedClient.configure { |config| config.max_retries = 3 }`")
    end
  end

  describe "a value that is not a count" do
    it "grades each one an error, since what the client makes of it is not something this check can grade" do
      unusable = ["5", Float::NAN, Float::INFINITY, Complex(1, 1), false]
      severities = unusable.map { |value| findings_for(configured_adapter_class(value)).map(&:severity) }

      expect(severities).to eq([[:error], [:error], [:error], [:error], [:error]])
    end

    # Infinity is the one value that looks like "retry forever". It is not: the retry middleware calls to_i on
    # it, which raises FloatDomainError before the first request leaves, so it is unusable and never unset.
    it "puts an infinite count here rather than beside nil, and still measures nothing from it" do
      infinite = findings_for(configured_adapter_class(Float::INFINITY)).fetch(0)

      expect(infinite.message).to include("a Float rather than a count of retries")
      expect(infinite.message).not_to include("Infinity", "no retry count")
    end

    it "describes a non-numeric value by its class and never echoes it into a report" do
      finding = findings_for(configured_adapter_class("5")).fetch(0)

      expect(finding.message).to include("a String rather than a count of retries")
      expect(finding.message).not_to include("5")
    end

    it "describes a Complex by its class rather than raising on a comparison it cannot make" do
      expect { Complex(1, 1) > 3 }.to raise_error(NoMethodError)

      finding = findings_for(configured_adapter_class(Complex(1, 1))).fetch(0)

      expect(finding.severity).to eq(:error)
      expect(finding.message).to include("a Complex rather than a count of retries")
      expect(finding.message).not_to include("1+1i")
    end

    # A String works at runtime - the middleware's to_i turns "5" into five retries - so the prose must not
    # claim every request fails on it, which is the timeout's complaint and not this setting's.
    it "does not claim the value fails every request, since a String is coerced into a count at runtime" do
      finding = findings_for(configured_adapter_class("5")).fetch(0)

      expect(finding.message).not_to include("fails on that value")
      expect(finding.remediation)
        .to include("Set a whole number of retries, at or below 3",
                    "`FabricatedClient.configure { |config| config.max_retries = 3 }`")
    end

    # The description of the value already says it is not a count; the verdict clause that follows must not say
    # it again, on either provenance.
    it "says once that the value is not a count, whichever provenance renders it" do
      chosen = findings_for(configured_adapter_class("5")).fetch(0).message
      inherited = findings_for(defaulted_adapter_class("5")).fetch(0).message

      expect(chosen).to include("a String rather than a count of retries, so what the client makes of it")
      expect(inherited).to include("cannot be shown to have chosen, so what the client makes of it")
      expect([chosen.scan("count of retries").size, inherited.scan("count of retries").size]).to eq([1, 1])
    end
  end

  describe "a defaulted reading" do
    subject(:finding) { findings_for(defaulted_adapter_class(10)).fetch(0) }

    it "attributes the value to the client and never to a choice the app made" do
      expect(finding.message).to include("the client's own default", "cannot be shown to have chosen")
      expect(finding.message).not_to include("is configured with")
    end

    it "warns when the inherited value is over the threshold, naming both numbers" do
      expect(finding.severity).to eq(:warning)
      expect(finding.message).to include("[10/3]")
    end

    it "does not fall silent at the limit, since a value nobody chose can move on a bundle update" do
      inside = findings_for(defaulted_adapter_class(3))

      expect(inside.map(&:severity)).to eq([:info])
      expect(inside.fetch(0).message).to include("[3/3]")
      expect(inside.fetch(0).remediation)
        .to include("Write the value down", "`FabricatedClient.configure { |config| config.max_retries = 3 }`")
    end

    # The G40 guard. A :defaulted reading hard-sets value to nil and carries its number in default; a check
    # that read the wrong field on this branch would hand nil to classify, which grades it :unset and renders
    # a client running happily on its own default as having no retry count at all - a wrong verdict rather
    # than a crash, and one a :defaulted fixture built the obvious way cannot tell from the right one. Both
    # halves are asserted: the number that should be in the message, and the unset text that should not.
    it "reads the default through the reading's effective value, so a usable default is never reported as unset" do
      adapter_class = defaulted_adapter_class(3)
      reading = adapter_class.new.reading(:max_retries)
      message = findings_for(adapter_class).fetch(0).message

      expect([reading.state, reading.value, reading.default, reading.effective]).to eq([:defaulted, nil, 3, 3])
      expect(message).to include("3")
      expect(message).not_to include("no retry count")
    end

    it "warns on a client whose own default is no count, still without attributing it to the app" do
      unset = findings_for(defaulted_adapter_class(nil)).fetch(0)

      expect(unset.severity).to eq(:warning)
      expect(unset.message).to include("own default is no retry count", "cannot be shown to have chosen")
    end

    it "grades a default that is not a count an error too, still without blaming the app for it" do
      unusable = findings_for(defaulted_adapter_class("5")).fetch(0)

      expect(unusable.severity).to eq(:error)
      expect(unusable.message).to include("a String rather than a count of retries", "cannot be shown to have chosen")
      expect(unusable.message).not_to include("5")
    end
  end

  # AC4: a client that ships no retry setting retries nothing, which is a fact about transient failures and
  # not an unknown. Graded below the number-based branches, because bounded is the opposite of what this
  # family hunts - but graded, never silent.
  describe "an unsupported reading" do
    subject(:finding) { findings_for(unsupported_adapter_class).fetch(0) }

    it "reports that a failed call is never retried, at a lower severity than a count that is wrong" do
      expect(finding.severity).to eq(:info)
      expect(finding.message).to include("ships no retry setting", "never retried", "first attempt")
    end

    it "is not undetermined, since not applicable and unreadable are different claims" do
      expect(finding).not_to be_undetermined
      expect(finding.undetermined?).to be false
    end

    it "sends the fix outside the client, there being nothing inside it to set" do
      expect(finding.remediation).to include("Nothing to set on FabricatedClient", "outside the client",
                                             "at or below 3")
    end

    it "is a finding and not silence, which is AC4's whole point" do
      expect(findings_for(unsupported_adapter_class).size).to eq(1)
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
      expect(not_read.remediation).to include("still exposes `max_retries`")
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
      { configured: -> { configured_adapter_class(10) }, defaulted: -> { defaulted_adapter_class(10) },
        unsupported: -> { unsupported_adapter_class }, absent: -> { absent_adapter_class },
        unreadable: -> { unreadable_adapter_class } }
    end

    it "has a fixture for each of them, so the grading below cannot skip one it was never handed" do
      expect(fixtures.keys).to eq(LlmAudit::Adapters::Reading::STATES)
    end

    it "grades each through its own branch, at the severity that state's claim deserves" do
      graded = LlmAudit::Adapters::Reading::STATES.to_h do |state|
        adapter_class = fixtures.fetch(state).call
        [state, [adapter_class.new.reading(:max_retries).state, findings_for(adapter_class).map(&:severity)]]
      end

      expect(graded).to eq(configured: [:configured, [:warning]], defaulted: [:defaulted, [:warning]],
                           unsupported: [:unsupported, [:info]], absent: [:absent, [:undetermined]],
                           unreadable: [:unreadable, [:undetermined]])
    end

    it "raises for a state it was never taught, which Doctor degrades rather than losing the run" do
      speculative = Data.define(:state, :value, :default).new(state: :speculative, value: 10, default: nil)
      adapter_class = configured_adapter_class(10)
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
      first = configured_adapter_class(10)
      second = configured_adapter_class(20, gem_name: "second-client", client_constant: "SecondClient")

      messages = findings_for(first, second).map(&:message)

      expect(messages.size).to eq(2)
      expect(messages.first).to include("fabricated-client", "[10/3]")
      expect(messages.last).to include("second-client", "[20/3]")
    end

    # One finding per adapter holds because ruby_llm reads :defaulted 3 in a process that loaded it, which is
    # :info and never silent, or :absent in one that did not, which is undetermined; the chosen/within branch
    # is the only silent one and no listed client reaches it on its defaults.
    it "reads the gem-wide manifest when nothing is injected, one finding per listed adapter" do
      expect(described_class.new.call.map(&:check_id)).to eq([:max_retries] * LlmAudit.adapters.size)
    end

    it "reports the same findings twice over, so a run tells the same story as the one before it" do
      expect(described_class.new.call).to eq(described_class.new.call)
    end
  end
end
