# frozen_string_literal: true

require "open3"
require_relative "../../support/ruby_llm_client"

RSpec.describe LlmAudit::Adapters::RubyLlm do
  include_context "with a pristine RubyLLM configuration"

  subject(:adapter) { described_class.new }

  let(:canonical_settings) { LlmAudit::Adapters::Base::SETTINGS }

  describe "the declaration" do
    it "names the client's id, gem and constant, which for this client are three different strings" do
      expect([described_class.id, described_class.gem_name, described_class.client_constant])
        .to eq([:ruby_llm, "ruby_llm", "RubyLLM"])
    end

    it "reads back without instantiating the adapter, which is what lets an M2 cop reuse the declaration" do
      expect(described_class).not_to receive(:new)

      expect(described_class.metadata.settings).to eq(request_timeout: :request_timeout, max_retries: :max_retries)
    end

    it "maps both canonical settings to a real accessor, so no reading for this client is unsupported" do
      accessors = canonical_settings.map { |setting| described_class.accessor_for(setting) }

      expect(accessors).to eq(canonical_settings)
      expect(adapter.readings.values.map(&:state)).not_to include(:unsupported)
    end

    it "is the whole adapter: a declaration and the two readers, with nothing else added to Base's contract" do
      expect(described_class.instance_methods(false)).to contain_exactly(:configuration, :default_configuration)
    end

    it "reaches the real client rather than itself, which a class spelled RubyLLM could not do" do
      expect(adapter.send(:client_module)).to be(RubyLLM)
      expect(LlmAudit::Adapters.const_defined?(:RubyLLM, false)).to be(false)
    end
  end

  describe "#detected?" do
    it "is true when the host process has loaded the client" do
      expect(adapter).to be_detected
    end

    it "is false when the constant is gone, and does not raise" do
      hide_const("RubyLLM")

      expect { adapter.detected? }.not_to raise_error
      expect(adapter).not_to be_detected
    end

    it "is not memoized, so one instance cannot go on reporting a client it can no longer see" do
      expect(adapter).to be_detected

      hide_const("RubyLLM")

      expect(adapter).not_to be_detected
    end
  end

  # Almost every example in this file mutates the client's process-global configuration, and the shared
  # context is what swaps a fresh one in and puts the original back. The leak guard itself is not an example
  # here: it runs inside the context's `around`, ahead of the swap, because that is the only moment at which
  # the inherited global is still visible - an example asserting on RubyLLM.config always sees the object the
  # `around` just built, so it could never fail. What is worth asserting is the detector that guard calls.
  describe "the config isolation this file depends on" do
    it "lets an example mutate the client's process-global configuration" do
      RubyLLM.configure { |config| config.request_timeout = 1 }

      expect(RubyLLM.config.request_timeout).to eq(1)
    end

    it "spots a config an earlier example left mutated, which is what a forgotten shared context looks like" do
      mutated = RubyLLM::Configuration.new.tap { |config| config.request_timeout = 1 }

      expect(RubyLlmConfigIsolation.leaked_options(mutated)).to eq(%i[request_timeout])
    end

    it "reports the option's name and never its value, since the client's options include every api key" do
      mutated = RubyLLM::Configuration.new.tap { |config| config.openai_api_key = "sk-placeholder-not-a-key" }

      expect(RubyLlmConfigIsolation.leaked_options(mutated).inspect).to eq("[:openai_api_key]")
    end

    it "says nothing about a config nobody touched, so the guard cannot redden a clean run" do
      expect(RubyLlmConfigIsolation.leaked_options(RubyLLM::Configuration.new)).to be_empty
    end
  end

  describe "#configuration" do
    it "is the process-global object itself, so the report describes the config the app actually runs on" do
      expect(adapter.configuration).to be(RubyLLM.config)
    end

    it "memoizes it, so one run asks the client for its global exactly once and not once per setting" do
      allow(RubyLLM).to receive(:config).and_call_original

      adapter.readings

      expect(RubyLLM).to have_received(:config).once
    end
  end

  describe "#default_configuration" do
    it "is a pristine object and never the live one, which is what makes provenance observable" do
      expect(adapter.default_configuration).not_to be(RubyLLM.config)
    end

    it "reads the client's own defaults rather than a copy of the live values" do
      RubyLLM.configure { |config| config.request_timeout = 45 }

      expect(adapter.default_configuration.request_timeout).to eq(300)
    end

    it "builds it once per run, since constructing one expands paths and reads ENV" do
      allow(RubyLLM::Configuration).to receive(:new).and_call_original

      adapter.readings

      expect(RubyLLM::Configuration).to have_received(:new).once
    end
  end

  describe "reading a setting the host app chose" do
    it "reads back the request timeout the app actually has in effect, with the client's default beside it" do
      RubyLLM.configure { |config| config.request_timeout = 45 }

      expect(adapter.reading(:request_timeout))
        .to have_attributes(client: :ruby_llm, setting: :request_timeout, value: 45, default: 300,
                            state: :configured)
    end

    it "reads back the retry count the app actually has in effect" do
      RubyLLM.configure { |config| config.max_retries = 7 }

      expect(adapter.reading(:max_retries))
        .to have_attributes(client: :ruby_llm, setting: :max_retries, value: 7, default: 3, state: :configured)
    end

    it "counts such a reading as determined, because the app demonstrably chose the value" do
      RubyLLM.configure { |config| config.request_timeout = 45 }

      expect(adapter.reading(:request_timeout)).to be_determined
    end

    it "reads both settings in one pass, so an app that set both is reported on both" do
      RubyLLM.configure do |config|
        config.request_timeout = 45
        config.max_retries = 7
      end

      expect(adapter.readings.values.map { |reading| [reading.setting, reading.state, reading.value] })
        .to eq([[:request_timeout, :configured, 45], [:max_retries, :configured, 7]])
    end
  end

  describe "reading a setting the host app never touched" do
    it "reports it as defaulted with no value, rather than as a default the app is credited with choosing" do
      RubyLLM.configure { |config| config.request_timeout = 45 }

      expect(adapter.reading(:max_retries))
        .to have_attributes(setting: :max_retries, value: nil, default: 3, state: :defaulted)
    end

    it "counts it as undetermined, so an unconfigured client is never reported as a confident OK" do
      expect(adapter.readings.values).to all(be_undetermined)
    end

    it "cannot tell a value the app re-chose from the default, which is why defaulted is undetermined" do
      RubyLLM.configure { |config| config.request_timeout = RubyLLM::Configuration.new.request_timeout }

      expect(adapter.reading(:request_timeout)).to have_attributes(state: :defaulted, value: nil)
    end
  end

  describe "when the client gem is not loaded" do
    before { hide_const("RubyLLM") }

    it "reports every canonical setting as absent, carrying neither a value nor a default" do
      described = adapter.readings.values.map { |r| [r.setting, r.state, r.value, r.default] }

      expect(described).to eq([[:request_timeout, :absent, nil, nil], [:max_retries, :absent, nil, nil]])
    end

    it "reports them as undetermined, so an unloaded client never reads as a confident OK" do
      expect(adapter.readings.values).to all(be_undetermined)
    end

    it "does not raise while doing it, so one missing client cannot abort the audit" do
      expect { adapter.readings }.not_to raise_error
    end
  end

  describe "the client's own defaults, which this gem reads rather than declares" do
    it "still names request_timeout and max_retries, the two attributes every reading here depends on" do
      expect(RubyLLM::Configuration.new).to respond_to(:request_timeout, :max_retries)
    end

    it "still defaults them to 300 and 3, so an upstream change lands as a red build rather than a wrong report" do
      pristine = RubyLLM::Configuration.new

      expect([pristine.request_timeout, pristine.max_retries]).to eq([300, 3])
    end

    # ruby_llm registers each option's default on the class that declared it (Configuration.defaults is a
    # per-class ivar), so an anonymous subclass inherits the readers but none of the defaults, and its
    # instances answer nil for every setting left unstated. This stand-in therefore states both canonical
    # settings rather than one: it is ruby_llm as it shipped below 1.9.0, not a config with a single method.
    context "when the client's defaults are not the ones this version ships" do
      let(:client_at_its_pre_1_9_defaults) do
        Class.new(RubyLLM::Configuration) do
          def request_timeout = 120
          def max_retries = 3
        end
      end

      before { stub_const("RubyLLM::Configuration", client_at_its_pre_1_9_defaults) }

      it "derives the default from the client rather than hardcoding 300, which was 120 before ruby_llm 1.9.0" do
        expect(RubyLLM.config.request_timeout).to eq(300)
        expect(adapter.reading(:request_timeout))
          .to have_attributes(value: 300, default: 120, state: :configured)
      end

      it "takes every canonical setting off that same client, so the guard is not one accessor deep" do
        expect(adapter.reading(:max_retries)).to have_attributes(value: nil, default: 3, state: :defaulted)
      end
    end
  end

  describe "when the client is loaded but its own configuration API has drifted" do
    before { stub_const("RubyLLM::Configuration", Class.new) }

    it "reports drift in the client's own API as unreadable rather than aborting the audit" do
      expect(adapter.reading(:request_timeout)).to have_attributes(state: :unreadable, value: nil, default: nil)
      expect { adapter.readings }.not_to raise_error
    end

    it "counts that as undetermined, so a renamed client API never reads as a confident OK" do
      expect(adapter.readings.values).to all(be_undetermined)
    end
  end

  describe "the no-output invariant, exercised against the real client" do
    before { RubyLLM.configure { |config| config.request_timeout = 45 } }

    it "produces real readings, so the two silence examples below are not vacuous" do
      expect(adapter.readings.values.map(&:state)).to eq(%i[configured defaulted])
    end

    it "writes nothing to stdout while reading a real client's configuration" do
      expect { adapter.readings }.not_to output.to_stdout_from_any_process
    end

    it "writes nothing to stderr either, so a debug warn cannot creep into an adapter" do
      expect { adapter.readings }.not_to output.to_stderr_from_any_process
    end
  end

  describe "the runtime probe" do
    let(:probe) do
      'require "stringio"; require "support/rails_host"; require "ruby_llm"; ' \
        "RubyLLM.configure { |c| c.request_timeout = 45 }; " \
        "puts LlmAudit.adapters.flat_map { |a| a.new.readings.values }.map(&:inspect)"
    end

    let(:expected_readings) do
      ["#<data LlmAudit::Adapters::Reading client=:ruby_llm, setting=:request_timeout, " \
       "value=45, default=300, state=:configured>",
       "#<data LlmAudit::Adapters::Reading client=:ruby_llm, setting=:max_retries, " \
       "value=nil, default=3, state=:defaulted>"]
    end

    it "prints one chosen and one defaulted reading from a booted Rails host, so the command cannot rot" do
      stdout, stderr, status = Open3.capture3(
        RbConfig.ruby, "-I", File.expand_path("../../../lib", __dir__), "-I", File.expand_path("../..", __dir__),
        "-e", probe
      )

      expect([stdout.lines.map(&:chomp), status.exitstatus])
        .to eq([expected_readings, 0]), (stderr unless stderr.empty?)
    end
  end
end
