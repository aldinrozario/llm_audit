# frozen_string_literal: true

RSpec.describe LlmAudit::Checks::RequestTimeout do
  # Every adapter below is a real Adapters::Base subclass over a fabricated configuration rather than a
  # double, so each reading these examples grade is one the adapter layer genuinely produced. No client gem
  # is required from this file, directly or through a support file, which is what lets it run unchanged on
  # the client-absent CI leg - the one leg where :absent is a fact rather than a fixture. Every fixture
  # helper hands back a CLASS, because that is what Checks::Base#initialize takes and instantiates itself,
  # so each is named for it: `adapter` alone is left meaning an instance, the way it does in
  # spec/llm_audit/adapters/base_spec.rb, whose own fixtures return one.
  let(:config_class) { Data.define(:request_timeout, :max_retries) }
  let(:canonical_settings) { { request_timeout: :request_timeout, max_retries: :max_retries } }
  let(:client_default) { 300 }

  def timeout_config(timeout) = config_class.new(request_timeout: timeout, max_retries: 3)

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

  # 300 is the value the pristine side is built from, so passing it would produce a :defaulted reading under
  # a helper named for the opposite state - the one fixture mistake a file about provenance cannot make
  # quietly.
  def configured_adapter_class(value, **options)
    raise ArgumentError, "#{value} is the client default and reads as :defaulted" if value == client_default

    loaded(adapter_class_over(timeout_config(value), timeout_config(client_default), **options))
  end

  def defaulted_adapter_class(value) = loaded(adapter_class_over(timeout_config(value), timeout_config(value)))
  def unreadable_adapter_class = loaded(adapter_class_over(Object.new, Object.new))

  def unsupported_adapter_class
    loaded(adapter_class_over(timeout_config(600), timeout_config(client_default),
                              settings: { request_timeout: nil, max_retries: :max_retries }))
  end

  # A second constant, stubbed nowhere in this file, so absence survives an example that also loads a
  # client. The gem name stays the one every other fixture uses, which is what leaves the absent/unreadable
  # inequality below about the claim being made rather than about which client made it.
  def absent_adapter_class
    adapter_class_over(timeout_config(600), timeout_config(client_default),
                       client_constant: "UnloadedClient")
  end

  def findings_for(*adapters, **options) = described_class.new(adapters: adapters, **options).call

  describe "the check contract" do
    it "is a check, so the registry can run it the one way it runs every other" do
      expect(described_class.ancestors).to include(LlmAudit::Checks::Base)
    end

    it "declares its id, severity and reference without being instantiated" do
      expect(described_class).not_to receive(:new)

      expect([described_class.id, described_class.default_severity, described_class.owasp_reference])
        .to eq([:request_timeout, :warning, "LLM06:2026 Unbounded Consumption"])
    end

    it "is reachable through the gem-wide registry, which is the list Doctor runs" do
      expect(LlmAudit.registry.fetch(:request_timeout)).to eq(described_class)
    end

    it "grades itself :warning, because the same value is wrong in a web request and right in a job" do
      expect(described_class.default_severity).to eq(:warning)
      expect(LlmAudit::Severity.declarable?(described_class.default_severity)).to be true
    end
  end

  describe "the threshold" do
    it "ships 30 seconds, the platform limit a stalled request runs into before any client's own" do
      expect(described_class::DEFAULT_THRESHOLD_SECONDS).to eq(30)
    end

    it "takes it as a defaulted keyword argument, so Doctor still builds this check with no arguments" do
      expect(described_class.instance_method(:initialize).parameters).to include(%i[key threshold])
      expect { described_class.new }.not_to raise_error
    end

    it "fires above the threshold and not at it, sparing an app that deliberately chose the limit" do
      expect(findings_for(configured_adapter_class(30))).to be_empty
      expect(findings_for(configured_adapter_class(31)).map(&:severity)).to eq([:warning])
    end

    it "compares against the injected threshold, so the comparison site names no literal" do
      expect(findings_for(configured_adapter_class(600))).not_to be_empty
      expect(findings_for(configured_adapter_class(600), threshold: 600)).to be_empty
    end

    # The comparison and the text are two separate reads of the same threshold, so grading against one number
    # while advising the operator about another is a state this check can reach. Both halves are pinned here:
    # the number the message quotes and the number the remediation tells the reader to write down.
    it "renders the threshold it graded against, so the number reported is the number compared" do
      finding = findings_for(configured_adapter_class(600), threshold: 100).fetch(0)

      expect(finding.message).to include("over the 100s", "[600/100]")
      expect(finding.remediation).to include("at or below 100s", "config.request_timeout = 100")
    end
  end

  describe "a configured reading" do
    subject(:finding) { findings_for(configured_adapter_class(600)).fetch(0) }

    it "warns over the threshold, naming both the value read and the limit it broke" do
      expect(finding.severity).to eq(:warning)
      expect(finding.message).to include("600s", "[600/30]")
    end

    it "reports it at the symbolic config location, carrying the check's own id and reference" do
      expect(finding.location).to eq(LlmAudit::Finding::CONFIG_LOCATION)
      expect(finding).to be_symbolic_location
      expect([finding.check_id, finding.owasp_reference])
        .to eq([:request_timeout, "LLM06:2026 Unbounded Consumption"])
    end

    it "says what the value costs while it runs, without claiming it is a ceiling on the call" do
      expect(finding.message).to include("one attempt")
      expect(finding.message).not_to match(/ceiling|cannot exceed|maximum time/)
    end

    it "puts the literal configuration line in the remediation, so the fix is copied rather than inferred" do
      expect(finding.remediation)
        .to include("`FabricatedClient.configure { |config| config.request_timeout = 30 }`",
                    "config/initializers/fabricated-client.rb")
    end

    it "names the background-job case in the remediation, since it cannot see the call site" do
      expect(finding.remediation).to include("background job")
    end

    it "reports nothing at all inside the limit: a value the app chose and can defend" do
      expect(findings_for(configured_adapter_class(10))).to eq([])
    end

    it "accepts a Float, which is what a client that takes fractional seconds is configured with" do
      message = findings_for(configured_adapter_class(60.5)).fetch(0).message

      expect(message).to include("60.5s", "[60.5/30]")
    end

    # A Numeric that is neither Integer nor Float prints in its own notation, and Rational's is the one that
    # actively misleads: unnormalised, [600/1/30] reads as a fraction over a threshold rather than a value
    # over a limit. BigDecimal has the same shape, in "0.3e3s", but is not a dependency of this gem to load.
    it "renders such a Numeric as the number it is, so no notation of its own reaches the report" do
      whole = findings_for(configured_adapter_class(Rational(600, 1))).fetch(0).message
      fractional = findings_for(configured_adapter_class(Rational(121, 2))).fetch(0).message

      expect(whole).to include("600s", "[600/30]")
      expect(fractional).to include("60.5s", "[60.5/30]")
      expect([whole, fractional].join).not_to include("600/1", "121/2")
    end
  end

  describe "a configured nil" do
    subject(:finding) { findings_for(configured_adapter_class(nil)).fetch(0) }

    it "warns without grading it the extreme, since no deadline is not a measured one" do
      expect(finding.severity).to eq(:warning)
      expect(finding.message).to include("no finite request timeout")
      expect(finding.message).not_to match(/over the|\[/)
    end

    it "does not raise on the comparison, which `nil > 30` would" do
      expect { nil > 30 }.to raise_error(NoMethodError)
      expect { findings_for(configured_adapter_class(nil)) }.not_to raise_error
    end

    it "asks for a deadline rather than a smaller one, there being no value here to lower" do
      expect(finding.remediation)
        .to include("Give the client a deadline of its own, at or below 30s",
                    "`FabricatedClient.configure { |config| config.request_timeout = 30 }`")
    end
  end

  describe "a value no request can use" do
    it "grades each one an error, because every request through that client fails before a provider" do
      unusable = [0, -5, "600", Float::NAN, Float::INFINITY, Complex(1, 1)]
      severities = unusable.map { |value| findings_for(configured_adapter_class(value)).map(&:severity) }

      expect(severities).to eq([[:error], [:error], [:error], [:error], [:error], [:error]])
    end

    # Infinity is the one value that could plausibly read as "no deadline" instead. It does not: nil makes
    # Faraday skip the option and the HTTP stack applies its own default, while Infinity is truthy, reaches
    # Net::HTTP, and raises RangeError before the request leaves. So it belongs here and not beside nil.
    it "puts an infinite timeout here rather than beside nil, and still measures nothing from it" do
      infinite = findings_for(configured_adapter_class(Float::INFINITY)).fetch(0)
      unset = findings_for(configured_adapter_class(nil)).fetch(0)

      expect([infinite.severity, unset.severity]).to eq(%i[error warning])
      expect(infinite.message).to include("a Float rather than a positive number of seconds")
      expect(infinite.message).not_to include("Infinity", "no finite request timeout")
    end

    it "describes a non-numeric value by its class and never echoes it into a report" do
      finding = findings_for(configured_adapter_class("600")).fetch(0)

      expect(finding.message).to include("a String rather than a positive number of seconds")
      expect(finding.message).not_to include("600")
    end

    it "still prints a numeric one, which is safe and is the whole content of the complaint" do
      expect(findings_for(configured_adapter_class(0)).fetch(0).message).to include("0s")
    end

    # real? is asked before positive? and before the comparison because Complex answers neither: both
    # Complex(1, 1).positive? and Complex(1, 1) > 30 raise rather than returning false. Without that guard an
    # exotic configuration value leaves this check as an exception instead of as a finding.
    it "describes a Complex by its class rather than raising on a comparison it cannot make" do
      expect { Complex(1, 1).positive? }.to raise_error(NoMethodError)

      finding = findings_for(configured_adapter_class(Complex(1, 1))).fetch(0)

      expect(finding.severity).to eq(:error)
      expect(finding.message).to include("a Complex rather than a positive number of seconds")
      expect(finding.message).not_to include("1+1i")
    end

    it "asks for a positive number of seconds in the remediation, which is what the value is not" do
      expect(findings_for(configured_adapter_class("600")).fetch(0).remediation)
        .to include("Set a positive number of seconds, at or below 30s",
                    "`FabricatedClient.configure { |config| config.request_timeout = 30 }`")
    end
  end

  describe "a defaulted reading" do
    subject(:finding) { findings_for(defaulted_adapter_class(600)).fetch(0) }

    it "attributes the value to the client and never to a choice the app made" do
      expect(finding.message).to include("the client's own default", "cannot be shown to have chosen")
      expect(finding.message).not_to include("is configured with")
    end

    it "does not claim the app configured nothing, which an app assigning the default would disprove" do
      expect(finding.message).not_to match(/never configured|did not configure|has no configured/)
    end

    it "warns when the inherited value is over the threshold, naming both numbers" do
      expect(finding.severity).to eq(:warning)
      expect(finding.message).to include("600s", "[600/30]")
    end

    it "does not fall silent inside the limit, since a value nobody chose can move on a bundle update" do
      inside = findings_for(defaulted_adapter_class(10))

      expect(inside.map(&:severity)).to eq([:info])
      expect(inside.fetch(0).message).to include("10s", "[10/30]")
      expect(inside.fetch(0).remediation)
        .to include("Write the value down so it cannot move without a review",
                    "`FabricatedClient.configure { |config| config.request_timeout = 10 }`")
    end

    it "reads the default, because a defaulted reading carries no value to read" do
      adapter_class = defaulted_adapter_class(600)
      reading = adapter_class.new.reading(:request_timeout)

      expect([reading.state, reading.value, reading.default]).to eq([:defaulted, nil, 600])
      expect(findings_for(adapter_class).fetch(0).message).to include("600s")
    end

    it "warns on a client whose own default is no timeout, still without attributing it to the app" do
      unset = findings_for(defaulted_adapter_class(nil)).fetch(0)

      expect(unset.severity).to eq(:warning)
      expect(unset.message).to include("no finite request timeout", "cannot be shown to have chosen")
    end

    it "grades a default no request can use an error too, still without blaming the app for it" do
      unusable = findings_for(defaulted_adapter_class("600")).fetch(0)

      expect(unusable.severity).to eq(:error)
      expect(unusable.message).to include("a String rather than a positive number of seconds",
                                          "cannot be shown to have chosen")
      expect(unusable.message).not_to include("600")
    end
  end

  describe "an unsupported reading" do
    subject(:finding) { findings_for(unsupported_adapter_class).fetch(0) }

    it "says the client ships no such setting, which is a fact and not an unknown" do
      expect(finding.severity).to eq(:info)
      expect(finding.message).to include("ships no request timeout setting")
    end

    it "is not undetermined, since not applicable and unreadable are different claims" do
      expect(finding).not_to be_undetermined
      expect(finding.undetermined?).to be false
    end

    it "sends the fix outside the client, there being nothing inside it to set" do
      expect(finding.remediation).to include("Nothing to set on FabricatedClient",
                                             "Rack-level or job-level timeout")
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

    # Both fixtures carry the same gem name, so an inequality alone would survive the two fixes being swapped
    # at their call sites - which would tell every absent client to look for a renamed accessor and every
    # unreadable one to boot the host app. Each is pinned to the problem it actually describes.
    it "sends each to its own fix, since a client to boot and a renamed accessor are different problems" do
      not_loaded = findings_for(absent_adapter_class).fetch(0)
      not_read = findings_for(unreadable_adapter_class).fetch(0)

      expect(not_loaded.remediation).not_to eq(not_read.remediation)
      expect(not_loaded.remediation).to include("`rails llm_audit:doctor` boots the host app first")
      expect(not_read.remediation).to include("still exposes `request_timeout`")
    end
  end

  describe "an unreadable reading" do
    subject(:finding) { findings_for(unreadable_adapter_class).fetch(0) }

    it "reports it through the builder that takes no severity, so no check could have graded it" do
      expect([finding.severity, finding.undetermined?])
        .to eq([LlmAudit::Severity::UNDETERMINED, true])
      expect(LlmAudit::Severity.declarable?(finding.severity)).to be false
    end

    it "reports no number, having read none" do
      expect(finding.message).to include("could not be read")
      expect(finding.message).not_to match(/\d/)
    end
  end

  describe "every state the adapter layer can report" do
    let(:fixtures) do
      { configured: -> { configured_adapter_class(600) }, defaulted: -> { defaulted_adapter_class(600) },
        unsupported: -> { unsupported_adapter_class }, absent: -> { absent_adapter_class },
        unreadable: -> { unreadable_adapter_class } }
    end

    it "has a fixture for each of them, so the grading below cannot skip one it was never handed" do
      expect(fixtures.keys).to eq(LlmAudit::Adapters::Reading::STATES)
    end

    # The state is read alongside the severity because two states share one severity: with only the severity
    # asserted, filing the absent fixture under :unreadable leaves this green while the :unreadable branch is
    # never exercised. Each adapter is built once and read twice, so its stub_const covers both halves.
    it "grades each through its own branch, at the severity that state's claim deserves" do
      graded = LlmAudit::Adapters::Reading::STATES.to_h do |state|
        adapter_class = fixtures.fetch(state).call
        [state, [adapter_class.new.reading(:request_timeout).state,
                 findings_for(adapter_class).map(&:severity)]]
      end

      expect(graded).to eq(configured: [:configured, [:warning]], defaulted: [:defaulted, [:warning]],
                           unsupported: [:unsupported, [:info]], absent: [:absent, [:undetermined]],
                           unreadable: [:unreadable, [:undetermined]])
    end

    it "raises for a state it was never taught, which Doctor degrades rather than losing the run" do
      speculative = Data.define(:state, :value, :default).new(state: :speculative, value: 600, default: nil)
      adapter_class = configured_adapter_class(600)
      adapter_class.define_method(:reading) { |_setting| speculative }

      expect { findings_for(adapter_class) }
        .to raise_error(LlmAudit::Error, /has no verdict for a :speculative reading/)
    end
  end

  describe "a value that is really a credential" do
    let(:leaky) do
      stub_const("LeakyConfiguration", Class.new do
        def inspect = %(#<LeakyConfiguration api_key="sk-leaked-key">)
      end)
    end

    it "never reaches the report, in either the message or the remediation" do
      expect(leaky.new.inspect).to include("sk-leaked-key")
      findings = [configured_adapter_class("sk-leaked-key"), configured_adapter_class(leaky.new)]
                 .flat_map { |adapter_class| findings_for(adapter_class) }

      expect(findings.map(&:severity)).to eq(%i[error error])
      expect(findings.flat_map { |f| [f.message, f.remediation] }.join("\n")).not_to include("sk-leaked")
    end
  end

  describe "the run as a whole" do
    it "reports once per adapter, since each client carries its own configuration" do
      first = configured_adapter_class(600)
      second = configured_adapter_class(120, gem_name: "second-client", client_constant: "SecondClient")

      messages = findings_for(first, second).map(&:message)

      expect(messages.size).to eq(2)
      expect(messages.first).to include("fabricated-client", "600s")
      expect(messages.last).to include("second-client", "120s")
    end

    # One finding per adapter is a property of the listed adapters and not a guarantee of the check: the
    # chosen/within branch is deliberately silent, so this holds only while no listed client reads as a
    # configured value inside the limit. RubyLLM's live configuration equals its pristine one in this process
    # unless an earlier example leaks a RubyLLM.configure into the global.
    it "reads the gem-wide manifest when nothing is injected, one finding per listed adapter" do
      expect(described_class.new.call.map(&:check_id)).to eq([:request_timeout] * LlmAudit.adapters.size)
    end

    it "reports the same findings twice over, so a run tells the same story as the one before it" do
      expect(described_class.new.call).to eq(described_class.new.call)
    end
  end
end
