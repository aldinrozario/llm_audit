# frozen_string_literal: true

RSpec.describe LlmAudit::Adapters::Reading do
  def attributes(**overrides)
    {
      client: :ruby_llm,
      setting: :request_timeout,
      value: 30,
      default: 300,
      state: :configured
    }.merge(overrides)
  end

  def build(**overrides)
    described_class.new(**attributes(**overrides))
  end

  def build_valueless(state, **overrides)
    build(state: state, value: nil, default: nil, **overrides)
  end

  describe "the five fields" do
    it "carries exactly client, setting, value, default and state" do
      expect(build.to_h.keys).to eq(%i[client setting value default state])
    end

    it "exposes every field unchanged" do
      expect(build).to have_attributes(attributes)
    end

    it "requires every field" do
      expect { described_class.new(**attributes.except(:state)) }
        .to raise_error(ArgumentError, /missing keyword: :state/)
    end

    it "is frozen" do
      expect(build).to be_frozen
    end

    it "compares by value" do
      expect(build).to eq(build)
      expect(build.hash).to eq(build.hash)
    end

    it "differs from a reading with a different field" do
      expect(build).not_to eq(build(value: 15))
    end

    it "has no severity field, so an adapter cannot grade what it read" do
      expect(described_class.members).to include(:state)
      expect(described_class.members).not_to include(:severity)
    end
  end

  describe "the constant vocabulary" do
    it "names the five states a reading may report" do
      expect(described_class::STATES).to eq(%i[configured defaulted unsupported absent unreadable])
    end

    it "counts only configured and unsupported as determined" do
      expect(described_class::DETERMINED_STATES).to eq(%i[configured unsupported])
    end

    it "counts only configured and defaulted as carrying a default" do
      expect(described_class::DEFAULT_BEARING_STATES).to eq(%i[configured defaulted])
    end

    it "freezes all three collections" do
      expect(described_class::STATES).to be_frozen
      expect(described_class::DETERMINED_STATES).to be_frozen
      expect(described_class::DEFAULT_BEARING_STATES).to be_frozen
    end

    it "shares no symbol with Severity::ALL, so an adapter cannot smuggle a severity through its state" do
      expect(LlmAudit::Severity::ALL).not_to be_empty
      expect(described_class::STATES & LlmAudit::Severity::ALL).to be_empty
    end

    it "scopes its constants to Reading, not to LlmAudit::Adapters" do
      expect(described_class.constants).to contain_exactly(
        :CONFIGURED, :DEFAULTED, :UNSUPPORTED, :ABSENT, :UNREADABLE,
        :STATES, :DETERMINED_STATES, :DEFAULT_BEARING_STATES
      )
      expect(LlmAudit::Adapters.constants)
        .not_to include(:CONFIGURED, :STATES, :DETERMINED_STATES, :DEFAULT_BEARING_STATES)
    end
  end

  describe ".valid_symbol?" do
    it "is the one symbol test the adapter layer shares, so a Reading and a Metadata cannot diverge on it" do
      expect(described_class.valid_symbol?(:request_timeout)).to be(true)
      expect(described_class.valid_symbol?("request_timeout")).to be(false)
      expect(described_class.valid_symbol?(nil)).to be(false)
    end
  end

  describe "client" do
    it "rejects a non-Symbol client, so attribution cannot drift into free text" do
      expect { build(client: "ruby_llm") }
        .to raise_error(ArgumentError, 'client must be a Symbol, got "ruby_llm"')
    end

    it "rejects nil" do
      expect { build(client: nil) }.to raise_error(ArgumentError, "client must be a Symbol, got nil")
    end
  end

  describe "setting" do
    it "rejects a non-Symbol setting, so a check cannot match on a near-miss string" do
      expect { build(setting: "request_timeout") }
        .to raise_error(ArgumentError, 'setting must be a Symbol, got "request_timeout"')
    end

    it "rejects nil" do
      expect { build(setting: nil) }.to raise_error(ArgumentError, "setting must be a Symbol, got nil")
    end
  end

  describe "state" do
    it "round-trips every state in the vocabulary" do
      described_class::STATES.each do |state|
        expect(build_valueless(state).state).to eq(state)
      end
    end

    it "rejects an unknown state" do
      expect { build_valueless(:missing) }
        .to raise_error(ArgumentError, "state must be one of " \
                                       "[:configured, :defaulted, :unsupported, :absent, :unreadable], got :missing")
    end

    it "rejects :undetermined, so the adapter vocabulary and the severity vocabulary stay disjoint" do
      expect { build_valueless(:undetermined) }.to raise_error(ArgumentError, /got :undetermined/)
    end

    it "rejects the string form of a state" do
      expect { build_valueless("configured") }.to raise_error(ArgumentError, /got "configured"/)
    end
  end

  describe "value" do
    (LlmAudit::Adapters::Reading::STATES - [LlmAudit::Adapters::Reading::CONFIGURED]).each do |state|
      it "refuses a value on any #{state} reading, so a check cannot read a number the adapter never obtained" do
        expect { build(state: state, value: 300, default: nil) }
          .to raise_error(ArgumentError, "a reading in state #{state.inspect} carries no value, got 300")
      end
    end

    it "allows a nil value on a configured reading, because an app that set no timeout has chosen one" do
      expect(build(value: nil)).to have_attributes(value: nil, state: :configured)
    end

    it "keeps a configured false unchanged, so a disabled setting is not mistaken for an unread one" do
      expect(build(value: false).value).to be false
    end

    it "refuses a false value on an unread reading, so a disabled setting cannot be invented for one" do
      expect { build(state: :absent, value: false, default: nil) }
        .to raise_error(ArgumentError, "a reading in state :absent carries no value, got false")
    end
  end

  describe "default" do
    it "carries the client's own default beside a configured value, so remediation need not hardcode it" do
      expect(build.default).to eq(300)
    end

    it "carries the default in effect on a defaulted reading" do
      expect(build(state: :defaulted, value: nil)).to have_attributes(value: nil, default: 300)
    end

    (LlmAudit::Adapters::Reading::STATES - LlmAudit::Adapters::Reading::DEFAULT_BEARING_STATES).each do |state|
      it "refuses a default on any #{state} reading, because only a reading off a live client has one" do
        expect { build(state: state, value: nil, default: 300) }
          .to raise_error(ArgumentError, "a reading in state #{state.inspect} carries no default, got 300")
      end
    end

    it "refuses a false default on an unread reading, so a client default cannot be invented for one" do
      expect { build(state: :absent, value: nil, default: false) }
        .to raise_error(ArgumentError, "a reading in state :absent carries no default, got false")
    end
  end

  describe ".configured" do
    subject(:reading) do
      described_class.configured(client: :ruby_llm, setting: :request_timeout, value: 30, default: 300)
    end

    it "records that the app itself chose this value" do
      expect(reading).to eq(build)
    end

    it "reports itself as determined, so a check may act on it" do
      expect(reading).to be_determined
    end

    it "accepts a nil value, because choosing no timeout at all is still a choice" do
      expect(described_class.configured(client: :ruby_llm, setting: :request_timeout, value: nil, default: 300))
        .to have_attributes(value: nil, state: :configured)
    end
  end

  describe ".defaulted" do
    subject(:reading) { described_class.defaulted(client: :ruby_llm, setting: :request_timeout, default: 300) }

    it "reports the default in effect without claiming the app chose it" do
      expect(reading).to have_attributes(client: :ruby_llm, setting: :request_timeout,
                                         value: nil, default: 300, state: :defaulted)
    end

    it "reports itself as undetermined, so a default is never read back as an app decision" do
      expect(reading).to be_undetermined
    end

    it "takes no value parameter, so an unchosen default cannot arrive dressed as a value" do
      parameters = described_class.method(:defaulted).parameters.map(&:last)

      expect(parameters).to include(:default)
      expect(parameters).not_to include(:value)
    end
  end

  describe ".unsupported" do
    subject(:reading) { described_class.unsupported(client: :ruby_openai, setting: :max_retries) }

    it "reports a setting this client does not ship, with nothing read and nothing defaulted" do
      expect(reading).to have_attributes(client: :ruby_openai, setting: :max_retries,
                                         value: nil, default: nil, state: :unsupported)
    end

    it "reports itself as determined, because a client that ships no such setting is a fact, not a gap" do
      expect(reading).to be_determined
    end

    it "takes neither a value nor a default parameter, so a missing setting cannot arrive carrying one" do
      expect(described_class.method(:unsupported).parameters.map(&:last)).to contain_exactly(:client, :setting)
    end
  end

  describe ".absent" do
    subject(:reading) { described_class.absent(client: :ruby_llm, setting: :request_timeout) }

    it "reports that the client gem is not loaded in this process" do
      expect(reading).to have_attributes(value: nil, default: nil, state: :absent)
    end

    it "reports itself as undetermined, so an unloaded gem never reads as a confident OK" do
      expect(reading).to be_undetermined
    end

    it "takes no value parameter, so an unread setting cannot arrive carrying one" do
      expect(described_class.method(:absent).parameters.map(&:last)).to contain_exactly(:client, :setting)
    end
  end

  describe ".unreadable" do
    subject(:reading) { described_class.unreadable(client: :ruby_llm, setting: :request_timeout) }

    it "reports that the client is loaded but the value could not be obtained" do
      expect(reading).to have_attributes(value: nil, default: nil, state: :unreadable)
    end

    it "reports itself as undetermined, so client API drift surfaces instead of passing silently" do
      expect(reading).to be_undetermined
    end

    it "takes no value parameter, so a failed read cannot arrive carrying one" do
      expect(described_class.method(:unreadable).parameters.map(&:last)).to contain_exactly(:client, :setting)
    end
  end

  describe "#configured?" do
    it "is true only for a configured reading" do
      expect(build).to be_configured
    end

    (LlmAudit::Adapters::Reading::STATES - [LlmAudit::Adapters::Reading::CONFIGURED]).each do |state|
      it "is false for any #{state} reading" do
        expect(build_valueless(state)).not_to be_configured
      end
    end
  end

  describe "#determined?" do
    it "is true for a configured reading, which the app demonstrably set" do
      expect(build).to be_determined
    end

    it "is true for an unsupported reading, because an absent setting is a confident fact about the client" do
      expect(build_valueless(:unsupported)).to be_determined
    end

    it "is false for a defaulted reading, which the app cannot be shown to have chosen" do
      expect(build_valueless(:defaulted)).not_to be_determined
    end

    it "is false for an absent reading, because an unloaded gem tells us nothing about the app" do
      expect(build_valueless(:absent)).not_to be_determined
    end

    it "is false for an unreadable reading, because a failed read is not a passing one" do
      expect(build_valueless(:unreadable)).not_to be_determined
    end
  end

  describe "#undetermined?" do
    it "is the exact negation of #determined? for every state in the vocabulary" do
      expect(described_class::STATES).not_to be_empty

      described_class::STATES.each do |state|
        reading = build_valueless(state)

        expect(reading.undetermined?).to be(!reading.determined?)
      end
    end
  end

  describe "#with" do
    it "returns a copy carrying the replacement value" do
      expect(build.with(value: 15).value).to eq(15)
    end

    it "re-validates the replacement state" do
      expect { build.with(state: :missing) }.to raise_error(ArgumentError, /got :missing/)
    end

    it "re-validates the value against the replacement state, so a copy cannot strand a value on an unread setting" do
      expect { build.with(state: :absent, default: nil) }
        .to raise_error(ArgumentError, "a reading in state :absent carries no value, got 30")
    end

    it "leaves every other field untouched" do
      expect(build.with(value: 15)).to eq(build(value: 15))
    end

    it "returns the receiver itself when given no overrides" do
      reading = build

      expect(reading.with).to equal(reading)
    end

    it "rejects an unknown field" do
      expect { build.with(bogus: 1) }.to raise_error(ArgumentError, /unknown keyword: :bogus/)
    end

    it "returns a frozen copy" do
      expect(build.with(value: 15)).to be_frozen
    end

    it "defines #with itself, because Data#with bypasses a custom initialize below Ruby 3.3" do
      expect(described_class.instance_method(:with).owner).to eq(described_class)
    end
  end
end
