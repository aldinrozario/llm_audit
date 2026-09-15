# frozen_string_literal: true

require "open3"
require_relative "../../support/ruby_openai_client"

RSpec.describe LlmAudit::Adapters::RubyOpenai do
  include_context "with a pristine OpenAI configuration"

  subject(:adapter) { described_class.new }

  let(:canonical_settings) { LlmAudit::Adapters::Base::SETTINGS }

  # Stands in for a host whose service object hands OpenAI::Client.new the middleware block: the real client,
  # built the real way, with the block a host would write.
  def client_built_with(&middleware)
    allow(OpenAI::Client).to(receive(:new).and_wrap_original { |build, *args| build.call(*args, &middleware) })
  end

  describe "the declaration" do
    it "names the client's id, gem and constant, which for this client are three different strings" do
      expect([described_class.id, described_class.gem_name, described_class.client_constant])
        .to eq([:ruby_openai, "ruby-openai", "OpenAI"])
    end

    it "reads back without instantiating the adapter, which is what lets an M2 cop reuse the declaration" do
      expect(described_class).not_to receive(:new)

      expect(described_class.metadata.settings)
        .to eq(request_timeout: :request_timeout, max_retries: :max_retries, max_output_tokens: nil)
    end

    it "maps the timeout and the retries to real accessors and declares the output-token cap unsupported, " \
       "since ruby-openai has no global cap" do
      accessors = canonical_settings.map { |setting| described_class.accessor_for(setting) }

      expect(accessors).to eq([:request_timeout, :max_retries, nil])
      expect(adapter.reading(:max_output_tokens)).to have_attributes(state: :unsupported, value: nil, default: nil)
    end

    it "is the whole adapter: a declaration, the two readers, a private hook that narrows the retry setting at " \
       "runtime, the three private helpers behind that reading, and two constants - nothing public beyond " \
       "Base's contract" do
      expect(described_class.instance_methods(false)).to contain_exactly(:configuration, :default_configuration)
      expect(described_class.private_instance_methods(false))
        .to contain_exactly(:ships?, :retry_count, :retry_handler, :connection)
      expect(described_class.constants(false)).to contain_exactly(:Facade, :RETRY_MIDDLEWARE)
    end

    it "reaches the real client rather than itself, which a class spelled OpenAI could not do" do
      expect(adapter.send(:client_module)).to be(OpenAI)
      expect(LlmAudit::Adapters.const_defined?(:OpenAI, false)).to be(false)
    end
  end

  # #detected? is where the client-absent path forks, and the readings that path produces are specced in
  # spec/llm_audit/adapters/client_absent_spec.rb rather than here: that file does not require the client,
  # so the client-absent CI leg - which excludes this file - is the one place absence is not a hide_const
  # fake. The same three examples run there against real absence and, on every other leg, against this one.
  describe "#detected?" do
    it "is true when the host process has loaded the client" do
      expect(adapter).to be_detected
    end

    it "is false when the constant is gone, and does not raise" do
      hide_const("OpenAI")

      expect { adapter.detected? }.not_to raise_error
      expect(adapter).not_to be_detected
    end

    it "is not memoized, so one instance cannot go on reporting a client it can no longer see" do
      expect(adapter).to be_detected

      hide_const("OpenAI")

      expect(adapter).not_to be_detected
    end
  end

  # Almost every example in this file mutates the client's process-global configuration, and the shared
  # context is what swaps a fresh one in and puts the original back. The leak guard itself is not an example
  # here: it runs inside the context's `around`, ahead of the swap, because that is the only moment at which
  # the inherited global is still visible - an example asserting on OpenAI.configuration always sees the
  # object the `around` just built, so it could never fail. What is worth asserting is the detector that
  # guard calls.
  describe "the config isolation this file depends on" do
    it "lets an example mutate the client's process-global configuration" do
      OpenAI.configure { |config| config.request_timeout = 1 }

      expect(OpenAI.configuration.request_timeout).to eq(1)
    end

    it "spots a config an earlier example left mutated, which is what a forgotten shared context looks like" do
      mutated = OpenAI::Configuration.new.tap { |config| config.request_timeout = 1 }

      expect(RubyOpenaiConfigIsolation.leaked_options(mutated)).to eq(%i[request_timeout])
    end

    it "reports the option's name and never its value, since the client's options include the access token" do
      mutated = OpenAI::Configuration.new.tap { |config| config.access_token = "sk-placeholder-not-a-key" }

      expect(RubyOpenaiConfigIsolation.leaked_options(mutated).inspect).to eq("[:access_token]")
    end

    it "says nothing about a config nobody touched, so the guard cannot redden a clean run" do
      expect(RubyOpenaiConfigIsolation.leaked_options(OpenAI::Configuration.new)).to be_empty
    end
  end

  describe "#configuration" do
    it "reads the timeout off the process-global configuration, so the report describes the config the app " \
       "actually runs on" do
      OpenAI.configure { |config| config.request_timeout = 45 }

      expect(adapter.configuration.request_timeout).to eq(45)
    end

    it "does not build a client to read the timeout, so a client that cannot be built still has a readable " \
       "timeout" do
      expect(OpenAI::Client).not_to receive(:new)

      adapter.reading(:request_timeout)
    end

    # Pinned on the timeout path and not on a full pass: reading the retries builds a client, and the
    # client's own constructor reads the global once per option it copies, which would drown the one read
    # the memo is for.
    it "memoizes the facade, so one run reads the client's global once and not once per setting" do
      allow(OpenAI).to receive(:configuration).and_call_original

      2.times { adapter.reading(:request_timeout) }

      expect(OpenAI).to have_received(:configuration).once
    end

    it "builds the client once per run, since its connection runs the host's middleware block" do
      allow(OpenAI::Client).to receive(:new).and_call_original

      adapter.readings
      adapter.readings

      expect(OpenAI::Client).to have_received(:new).once
    end
  end

  describe "#default_configuration" do
    it "reads the client's own default rather than a copy of the live value" do
      OpenAI.configure { |config| config.request_timeout = 45 }

      expect(adapter.default_configuration.request_timeout).to eq(120)
    end

    it "carries no retry count, since the client ships none of its own" do
      expect(adapter.default_configuration.max_retries).to be_nil
    end

    it "builds the pristine configuration once per run" do
      allow(OpenAI::Configuration).to receive(:new).and_call_original

      adapter.readings

      expect(OpenAI::Configuration).to have_received(:new).once
    end
  end

  describe "reading a setting the host app chose" do
    it "reads back the request timeout the app actually has in effect, with the client's default beside it" do
      OpenAI.configure { |config| config.request_timeout = 45 }

      expect(adapter.reading(:request_timeout))
        .to have_attributes(client: :ruby_openai, setting: :request_timeout, value: 45, default: 120,
                            state: :configured)
    end

    it "counts such a reading as determined, because the app demonstrably chose the value" do
      OpenAI.configure { |config| config.request_timeout = 45 }

      expect(adapter.reading(:request_timeout)).to be_determined
    end

    it "reads a timeout the app switched off as configured false, so the check can grade it as unusable" do
      OpenAI.configure { |config| config.request_timeout = false }

      expect(adapter.reading(:request_timeout)).to have_attributes(value: false, default: 120, state: :configured)
    end

    it "reads a timeout the app set to nil as configured nil, since an app that set no timeout chose one" do
      OpenAI.configure { |config| config.request_timeout = nil }

      expect(adapter.reading(:request_timeout)).to have_attributes(value: nil, default: 120, state: :configured)
    end

    it "reads every setting in one pass, so a stock install with a chosen timeout is reported on all three" do
      OpenAI.configure { |config| config.request_timeout = 45 }

      expect(adapter.readings.values.map { |reading| [reading.setting, reading.state, reading.value] })
        .to eq([[:request_timeout, :configured, 45], [:max_retries, :unsupported, nil],
                [:max_output_tokens, :unsupported, nil]])
    end
  end

  describe "reading a setting the host app never touched" do
    it "reports it as defaulted with no value, rather than as a default the app is credited with choosing" do
      expect(adapter.reading(:request_timeout))
        .to have_attributes(setting: :request_timeout, value: nil, default: 120, state: :defaulted)
    end

    it "counts it as undetermined, so an unconfigured client is never reported as a confident OK" do
      expect(adapter.readings.values.map(&:state)).to eq(%i[defaulted unsupported unsupported])
      expect(adapter.reading(:request_timeout)).to be_undetermined
    end

    it "cannot tell a value the app re-chose from the default, which is why defaulted is undetermined" do
      OpenAI.configure { |config| config.request_timeout = OpenAI::Configuration.new.request_timeout }

      expect(adapter.reading(:request_timeout)).to have_attributes(state: :defaulted, value: nil)
    end

    it "derives the default from the client rather than hardcoding 120" do
      stub_const("OpenAI::Configuration", Class.new(OpenAI::Configuration) { def request_timeout = 60 })

      expect(adapter.reading(:request_timeout)).to have_attributes(value: 120, default: 60, state: :configured)
    end
  end

  # The setting where this adapter differs from ruby_llm's shape: ruby-openai has no retry setting, and
  # retries only if the host adds faraday-retry middleware to the client's connection. A stock install
  # therefore reads :unsupported - a determined fact, and the one the retry check has teeth on - and a host
  # that did add the middleware reads its max as :configured. Both are read off the connection the client
  # really builds, never off a copy.
  describe "the retry middleware the host may add to its connection" do
    it "reports retries as unsupported on a default install, since nothing on the connection retries" do
      expect(adapter.reading(:max_retries))
        .to have_attributes(client: :ruby_openai, setting: :max_retries, value: nil, default: nil,
                            state: :unsupported)
    end

    it "counts that as determined, because a connection with no retry middleware is a fact and not an unknown" do
      expect(adapter.reading(:max_retries)).to be_determined
    end

    it "is right that the default connection really carries none, so the reading above is not a stub's" do
      handlers = OpenAI::Client.new.send(:conn).builder.handlers.map(&:name)

      expect(handlers).not_to be_empty
      expect(handlers.grep(/Retry/)).to be_empty
    end

    it "declares no dependency on faraday-retry, so a default install cannot retry" do
      expect(Gem.loaded_specs["ruby-openai"].dependencies.map(&:name)).not_to include("faraday-retry")
    end

    it "reads a default install without naming the middleware's constants, which such a host has not loaded" do
      hide_const("Faraday::Retry")

      expect(adapter.reading(:max_retries)).to have_attributes(state: :unsupported)
    end

    it "reads back the max a host wrote into the middleware as the retry count it chose" do
      client_built_with { |f| f.request :retry, max: 5 }

      expect(adapter.reading(:max_retries)).to have_attributes(value: 5, default: nil, state: :configured)
      expect(adapter.reading(:max_retries)).to be_determined
    end

    it "reads the max however the host spelled the options, since Faraday accepts them positionally too" do
      client_built_with { |f| f.request :retry, { max: 4 } }

      expect(adapter.reading(:max_retries)).to have_attributes(value: 4, state: :configured)
    end

    it "matches the middleware by ancestry and never by position, so a host's subclass placed mid-stack is " \
       "still found" do
      stub_const("RetryingLikeTheHost", Class.new(Faraday::Retry::Middleware))
      client_built_with do |f|
        f.use RetryingLikeTheHost, max: 9
        f.request :url_encoded
      end

      expect(adapter.reading(:max_retries)).to have_attributes(value: 9, state: :configured)
    end

    it "still matches a subclass the host never named, whose own name is nil" do
      client_built_with { |f| f.use Class.new(Faraday::Retry::Middleware), max: 11 }

      expect(adapter.reading(:max_retries)).to have_attributes(value: 11, state: :configured)
    end

    it "reads the count as written, never the middleware's fallback of 2" do
      client_built_with { |f| f.request :retry }

      expect(Faraday::Retry::Middleware::Options.from(max: nil).max).to eq(2)
      expect(adapter.reading(:max_retries)).to have_attributes(value: nil, default: nil, state: :defaulted)
    end

    # The route a host has to a client it never constructs itself: a builder installed process-wide through
    # Faraday.default_connection_options is what every Faraday.new picks up, the client's included.
    describe "when the host installed its retry through Faraday's default builder" do
      let(:retrying_builder) do
        Class.new(Faraday::RackBuilder) do
          def initialize(&)
            super
            request(:retry, max: 7)
          end
        end
      end

      around do |example|
        saved = Faraday.default_connection_options
        Faraday.default_connection_options = { builder_class: retrying_builder }
        example.run
      ensure
        Faraday.default_connection_options = saved
      end

      it "reads the max off the connection the client really built, beside the timeout the app chose" do
        OpenAI.configure { |config| config.request_timeout = 45 }

        expect(adapter.readings.values.map { |reading| [reading.setting, reading.state, reading.value] })
          .to eq([[:request_timeout, :configured, 45], [:max_retries, :configured, 7],
                  [:max_output_tokens, :unsupported, nil]])
      end
    end
  end

  # Reading the retries means building a client, and below ruby-openai 7.0 a client with no access token
  # does not build. What must hold is that the failure stays with the setting it belongs to: the retries read
  # unreadable, the timeout - read off the configuration, never the client - stays readable, and nothing
  # raises out of the adapter.
  describe "when the client cannot be built" do
    before { OpenAI.configure { |config| config.request_timeout = 45 } }

    it "reports the retries as unreadable rather than aborting the audit" do
      allow(OpenAI::Client).to receive(:new).and_raise(OpenAI::ConfigurationError)

      expect(adapter.reading(:max_retries)).to have_attributes(state: :unreadable, value: nil, default: nil)
      expect(adapter.reading(:max_retries)).to be_undetermined
      expect { adapter.readings }.not_to raise_error
    end

    it "keeps the timeout readable, since that reading never needed the client" do
      allow(OpenAI::Client).to receive(:new).and_raise(OpenAI::ConfigurationError)

      expect(adapter.reading(:request_timeout)).to have_attributes(value: 45, default: 120, state: :configured)
    end

    it "is right that the client's own error is one the adapter's rescue draws its line around" do
      expect(OpenAI::ConfigurationError).to be < StandardError
    end

    it "reports the retries as unreadable when the host's middleware block raises, since that block runs " \
       "on every connection build" do
      client_built_with { |_f| raise "the host's hook blew up" }

      expect(adapter.reading(:max_retries)).to have_attributes(state: :unreadable)
      expect { adapter.readings }.not_to raise_error
    end

    it "reports the retries as unreadable when the client no longer builds its connection where the adapter " \
       "looks" do
      stub_const("OpenAI::Client", Class.new(OpenAI::Client) { undef_method :conn })

      expect(adapter.reading(:max_retries)).to have_attributes(state: :unreadable)
    end

    it "reports both readable settings as unreadable when the host swapped OpenAI.configuration for " \
       "something else" do
      OpenAI.configuration = Object.new

      expect(adapter.readings.values.map(&:state)).to eq(%i[unreadable unreadable unsupported])
    end
  end

  # Also the example that pins the order of Base's support hook: the retries read unreadable here, never a
  # confident :unsupported, because a client whose Configuration has moved is drift before it is anything
  # else - asked ahead of the readers, the hook would build a client, find no middleware, and answer
  # "not shipped" about a client it can no longer read.
  describe "when the client is loaded but its own configuration API has drifted" do
    before { stub_const("OpenAI::Configuration", Class.new) }

    it "reports drift in the client's own API as unreadable rather than aborting the audit" do
      expect(adapter.readings.values.map(&:state)).to eq(%i[unreadable unreadable unsupported])
      expect { adapter.readings }.not_to raise_error
    end

    it "counts that as undetermined, so a renamed client API never reads as a confident OK" do
      expect(adapter.readings.values_at(:request_timeout, :max_retries)).to all(be_undetermined)
      expect(adapter.reading(:max_output_tokens).state).to eq(:unsupported)
    end
  end

  # The official openai SDK claims the same constant and none of this client's shape: no OpenAI.configuration,
  # no OpenAI::Configuration. Telling the two apart is M2's; what holds today is that such a host is never a
  # pass.
  describe "on a host whose OpenAI is not ruby-openai" do
    before { stub_const("OpenAI", Module.new) }

    it "detects the constant and reads the client as loaded but unreadable, never as OK" do
      expect(adapter).to be_detected
      expect(adapter.readings.values.map(&:state)).to eq(%i[unreadable unreadable unsupported])
      expect(adapter.readings.values_at(:request_timeout, :max_retries)).to all(be_undetermined)
    end
  end

  describe "the client's own defaults, which this gem reads rather than declares" do
    it "still names request_timeout, the one attribute the timeout reading depends on" do
      expect(OpenAI::Configuration.new).to respond_to(:request_timeout)
    end

    it "still defaults it to 120, so an upstream change lands as a red build rather than a wrong report" do
      expect(OpenAI::Configuration.new.request_timeout).to eq(120)
    end

    it "still ships no retry setting and no output-token cap, so the declarations stay honest" do
      expect(OpenAI::Configuration.new).not_to respond_to(:max_retries, :max_tokens, :max_output_tokens)
    end

    it "still builds its connection in a private #conn the adapter reaches for" do
      expect(OpenAI::Client.private_method_defined?(:conn)).to be(true)
    end
  end

  # Building the client and its connection is construction only; had any read opened a socket, the IOError
  # would have surfaced through the rescue as an :unreadable reading.
  describe "the no-request invariant, exercised against the real client" do
    before { allow(TCPSocket).to receive(:open).and_raise(IOError) }

    it "reads every setting with sockets forbidden, so no read can have reached the provider" do
      expect(adapter.readings.values.map(&:state)).to eq(%i[defaulted unsupported unsupported])
    end
  end

  describe "the no-output invariant, exercised against the real client" do
    before { OpenAI.configure { |config| config.request_timeout = 45 } }

    it "produces real readings, so the two silence examples below are not vacuous" do
      expect(adapter.readings.values.map(&:state)).to eq(%i[configured unsupported unsupported])
    end

    it "produces a real retry reading too, once a host has wired the middleware" do
      client_built_with { |f| f.request :retry, max: 5 }

      expect(adapter.readings.values.map(&:state)).to eq(%i[configured configured unsupported])
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
      'require "stringio"; require "support/rails_host"; require "openai"; ' \
        "OpenAI.configure { |c| c.request_timeout = 45 }; " \
        "puts LlmAudit.adapters.flat_map { |a| a.new.readings.values }.map(&:inspect)"
    end

    let(:expected_readings) do
      ["#<data LlmAudit::Adapters::Reading client=:ruby_llm, setting=:request_timeout, " \
       "value=nil, default=nil, state=:absent>",
       "#<data LlmAudit::Adapters::Reading client=:ruby_llm, setting=:max_retries, " \
       "value=nil, default=nil, state=:absent>",
       "#<data LlmAudit::Adapters::Reading client=:ruby_llm, setting=:max_output_tokens, " \
       "value=nil, default=nil, state=:absent>",
       "#<data LlmAudit::Adapters::Reading client=:ruby_openai, setting=:request_timeout, " \
       "value=45, default=120, state=:configured>",
       "#<data LlmAudit::Adapters::Reading client=:ruby_openai, setting=:max_retries, " \
       "value=nil, default=nil, state=:unsupported>",
       "#<data LlmAudit::Adapters::Reading client=:ruby_openai, setting=:max_output_tokens, " \
       "value=nil, default=nil, state=:unsupported>"]
    end

    it "prints one chosen and two unsupported readings from a booted Rails host, and absent for the client " \
       "it did not load, so the command cannot rot" do
      stdout, stderr, status = Open3.capture3(
        RbConfig.ruby, "-I", File.expand_path("../../../lib", __dir__), "-I", File.expand_path("../..", __dir__),
        "-e", probe
      )

      expect([stdout.lines.map(&:chomp), status.exitstatus])
        .to eq([expected_readings, 0]), (stderr unless stderr.empty?)
    end
  end
end
