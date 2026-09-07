# frozen_string_literal: true

RSpec.describe LlmAudit::Adapters::Base do
  let(:config_class) { Data.define(:request_timeout, :max_retries) }
  let(:canonical_settings) { { request_timeout: :request_timeout, max_retries: :max_retries } }

  def declared_adapter(id: :fixture_client, gem_name: "fictional-client",
                       client_constant: "FictionalClient", settings: canonical_settings)
    Class.new(described_class) do
      declare id: id, gem_name: gem_name, client_constant: client_constant, settings: settings
    end
  end

  def autoloading_adapter
    adapter_class = declared_adapter(client_constant: "UnloadableClient")
    adapter_class.define_method(:configuration) { client_module.config }
    adapter_class.define_method(:default_configuration) { client_module.config }
    adapter_class.new
  end

  def reading_adapter(live:, pristine:, **overrides)
    adapter_class = declared_adapter(**overrides)
    adapter_class.define_method(:configuration) { live }
    adapter_class.define_method(:default_configuration) { pristine }
    adapter_class.new
  end

  def redeclare(adapter_class)
    adapter_class.send(:declare, id: :hijacked, gem_name: "hijacked", client_constant: "Hijacked",
                                 settings: canonical_settings)
  end

  def config(request_timeout: 300, max_retries: 3)
    config_class.new(request_timeout: request_timeout, max_retries: max_retries)
  end

  def metadata_attributes(**overrides)
    { id: :fixture_client, gem_name: "fictional-client", client_constant: "FictionalClient",
      settings: canonical_settings }.merge(overrides)
  end

  def build_metadata(**overrides)
    described_class::Metadata.new(**metadata_attributes(**overrides))
  end

  describe "SETTINGS" do
    it "is the one vocabulary every adapter answers, so a check asks each client the same question" do
      expect(described_class::SETTINGS).to eq(%i[request_timeout max_retries])
    end

    it "is frozen, so no adapter can widen the vocabulary for the others" do
      expect(described_class::SETTINGS).to be_frozen
    end
  end

  describe "Metadata" do
    it "carries exactly the four things an adapter declares about its client" do
      expect(described_class::Metadata.members).to eq(%i[id gem_name client_constant settings])
    end

    it "exposes every field unchanged" do
      expect(build_metadata).to have_attributes(id: :fixture_client, gem_name: "fictional-client",
                                                client_constant: "FictionalClient",
                                                settings: canonical_settings)
    end

    it "freezes what it builds" do
      expect(build_metadata).to be_frozen
    end

    it "freezes the settings map, so two adapters cannot share a mutable mapping" do
      mapping = { request_timeout: :request_timeout, max_retries: :max_retries }
      declared = build_metadata(settings: mapping)
      mapping[:request_timeout] = :hijacked

      expect(declared.settings).to be_frozen
      expect(declared.accessor_for(:request_timeout)).to eq(:request_timeout)
    end

    it "keeps id, gem name and constant apart, because for some clients they are three different strings" do
      expect(build_metadata(id: :ruby_openai, gem_name: "ruby-openai", client_constant: "OpenAI"))
        .to have_attributes(id: :ruby_openai, gem_name: "ruby-openai", client_constant: "OpenAI")
    end

    it "checks its symbols with Reading.valid_symbol?, so the layer holds one copy of the rule and not two" do
      allow(LlmAudit::Adapters::Reading).to receive(:valid_symbol?).and_call_original

      build_metadata(id: :fixture, settings: { request_timeout: :request_timeout, max_retries: nil })

      expect(LlmAudit::Adapters::Reading).to have_received(:valid_symbol?).with(:fixture)
      expect(LlmAudit::Adapters::Reading).to have_received(:valid_symbol?).with(:request_timeout)
    end

    it "rejects a non-Symbol id, so attribution cannot drift into free text" do
      expect { build_metadata(id: "fixture_client") }
        .to raise_error(ArgumentError, 'id must be a Symbol, got "fixture_client"')
    end

    it "rejects a blank gem name" do
      expect { build_metadata(gem_name: "   ") }
        .to raise_error(ArgumentError, 'gem_name must be a non-empty String, got "   "')
    end

    it "rejects a nil gem name" do
      expect { build_metadata(gem_name: nil) }
        .to raise_error(ArgumentError, "gem_name must be a non-empty String, got nil")
    end

    it "rejects a client constant that is not a constant name, which detection would raise a NameError on" do
      expect { build_metadata(client_constant: "ruby_llm") }
        .to raise_error(ArgumentError, 'client_constant must be a constant name, got "ruby_llm"')
    end

    it "rejects a Symbol client constant, since detection reads a constant path" do
      expect { build_metadata(client_constant: :RubyLLM) }
        .to raise_error(ArgumentError, "client_constant must be a constant name, got :RubyLLM")
    end

    it "accepts a namespaced client constant, because not every client is reached at the top level" do
      expect(build_metadata(client_constant: "Vendor::Client").client_constant).to eq("Vendor::Client")
    end

    it "rejects a settings map that is not a Hash" do
      expect { build_metadata(settings: nil) }.to raise_error(ArgumentError, "settings must be a Hash, got nil")
    end

    it "rejects a map that omits a canonical setting, because an omission is an oversight and a nil is a decision" do
      expect { build_metadata(settings: { request_timeout: :request_timeout }) }
        .to raise_error(ArgumentError, "settings must map exactly [:request_timeout, :max_retries], " \
                                       "got [:request_timeout]")
    end

    it "rejects a setting outside the canonical vocabulary, so an adapter cannot answer a question no check asks" do
      expect { build_metadata(settings: canonical_settings.merge(temperature: :temperature)) }
        .to raise_error(ArgumentError, /settings must map exactly \[:request_timeout, :max_retries\]/)
    end

    it "accepts the map in any order, since a declaration is a mapping and not a sequence" do
      expect(build_metadata(settings: { max_retries: :max_retries, request_timeout: :request_timeout }))
        .to eq(build_metadata)
    end

    it "accepts an explicit nil accessor, which is how a client says it ships no such setting" do
      expect(build_metadata(settings: canonical_settings.merge(max_retries: nil)).accessor_for(:max_retries))
        .to be_nil
    end

    it "rejects a non-Symbol accessor, so a mapping cannot drift into free text" do
      expect { build_metadata(settings: canonical_settings.merge(max_retries: "max_retries")) }
        .to raise_error(ArgumentError, 'the :max_retries accessor must be a Symbol or nil, got "max_retries"')
    end

    it "requires every field" do
      expect { described_class::Metadata.new(**metadata_attributes.except(:settings)) }
        .to raise_error(ArgumentError, /missing keyword: :settings/)
    end

    it "re-validates what #with copies, so a declaration cannot be edited into an invalid one" do
      expect { build_metadata.with(id: "hijacked") }
        .to raise_error(ArgumentError, 'id must be a Symbol, got "hijacked"')
    end

    it "defines #with itself, because Data#with bypasses a custom initialize below Ruby 3.3" do
      expect(described_class::Metadata.instance_method(:with).owner).to eq(described_class::Metadata)
    end
  end

  describe ".declare" do
    it "exposes the declaration as metadata on the class" do
      expect(declared_adapter.metadata).to eq(build_metadata)
    end

    it "reads back through the class-level accessors" do
      adapter_class = declared_adapter

      expect([adapter_class.id, adapter_class.gem_name, adapter_class.client_constant])
        .to eq([:fixture_client, "fictional-client", "FictionalClient"])
    end

    it "reads metadata without instantiating the adapter, which is what lets a cop use the same declaration" do
      adapter_class = declared_adapter
      expect(adapter_class).not_to receive(:new)

      expect([adapter_class.id, adapter_class.gem_name, adapter_class.accessor_for(:request_timeout)])
        .to eq([:fixture_client, "fictional-client", :request_timeout])
    end

    it "maps every canonical setting to the accessor the client exposes" do
      adapter_class = declared_adapter

      expect(described_class::SETTINGS.map { |setting| adapter_class.accessor_for(setting) })
        .to eq(%i[request_timeout max_retries])
    end

    it "answers nil for a setting outside the canonical vocabulary rather than raising" do
      expect(declared_adapter.accessor_for(:temperature)).to be_nil
    end

    it "is private, so an adapter's client cannot be reassigned from outside its own body" do
      adapter_class = declared_adapter

      expect { adapter_class.declare(id: :hijacked, gem_name: "hijacked", client_constant: "Hijacked", settings: {}) }
        .to raise_error(NoMethodError, /private method/)
    end

    it "refuses a second declaration, which would desync a reading from the client it names" do
      adapter_class = declared_adapter

      expect { redeclare(adapter_class) }
        .to raise_error(LlmAudit::Error, /#{Regexp.escape(adapter_class.metadata.inspect)}/)
    end

    it "keeps the first declaration when a second one is refused" do
      adapter_class = declared_adapter

      expect { redeclare(adapter_class) }.to raise_error(LlmAudit::Error, /already declared its metadata/)
      expect([adapter_class.id, adapter_class.client_constant]).to eq([:fixture_client, "FictionalClient"])
    end
  end

  describe ".metadata when nothing was declared" do
    it "raises an LlmAudit::Error rather than returning nil" do
      expect { Class.new(described_class).metadata }
        .to raise_error(LlmAudit::Error, /did not declare its metadata/)
    end

    it "names the offending class with inspect, so an anonymous adapter still reads back" do
      adapter_class = Class.new(described_class)

      expect { adapter_class.metadata }
        .to raise_error(LlmAudit::Error, /#{Regexp.escape(adapter_class.inspect)}/)
    end

    it "raises from every class-level accessor" do
      adapter_class = Class.new(described_class)

      expect { adapter_class.id }.to raise_error(LlmAudit::Error)
      expect { adapter_class.gem_name }.to raise_error(LlmAudit::Error)
      expect { adapter_class.client_constant }.to raise_error(LlmAudit::Error)
      expect { adapter_class.accessor_for(:request_timeout) }.to raise_error(LlmAudit::Error)
    end

    it "does not inherit a parent's metadata, so a subclass must declare its own client" do
      expect { Class.new(declared_adapter).metadata }
        .to raise_error(LlmAudit::Error, /did not declare its metadata/)
    end
  end

  describe "#detected?" do
    it "is true when the client constant is loaded in this process" do
      stub_const("FictionalClient", Module.new)

      expect(declared_adapter.new).to be_detected
    end

    it "is false when the client is not loaded, and does not raise" do
      expect(declared_adapter.new).not_to be_detected
    end

    it "does not consult Object's ancestors, so a constant on Kernel cannot be mistaken for the client" do
      stub_const("Kernel::FictionalClient", Module.new)

      expect(Object.const_defined?("FictionalClient")).to be(true)
      expect(declared_adapter.new).not_to be_detected
    end

    it "is not memoized, so one adapter instance cannot report a client it can no longer see" do
      stub_const("FictionalClient", Module.new)
      adapter = declared_adapter.new

      expect(adapter).to be_detected
      hide_const("FictionalClient")
      expect(adapter).not_to be_detected
    end

    it "asks const_defined? and never const_get, so detecting a client cannot autoload it" do
      allow(Object).to receive(:const_get).and_call_original

      expect(declared_adapter.new).not_to be_detected
      expect(Object).not_to have_received(:const_get).with("FictionalClient")
    end

    it "answers false rather than raising when the declared path is rooted at something that is not a module, " \
       "because a path Ruby cannot walk names no client this process has loaded" do
      stub_const("Brand", "acme")
      adapter = declared_adapter(client_constant: "Brand::Client").new

      expect { adapter.detected? }.not_to raise_error
      expect(adapter).not_to be_detected
    end

    it "is guarding a TypeError the primitive really does raise, so that answer is not a vacuous one" do
      stub_const("Brand", "acme")

      expect { Object.const_defined?("Brand::Client", false) }.to raise_error(TypeError)
      expect(declared_adapter(client_constant: "Brand::Client").new).not_to be_detected
    end
  end

  describe "#configuration" do
    it "raises NotImplementedError naming the class that failed to implement it" do
      adapter_class = declared_adapter

      expect { adapter_class.new.configuration }
        .to raise_error(NotImplementedError, /#{Regexp.escape(adapter_class.inspect)} must implement/)
    end

    it "names the method, so an adapter author is told which half is missing" do
      expect { declared_adapter.new.configuration }
        .to raise_error(NotImplementedError, /must implement #configuration/)
    end
  end

  describe "#default_configuration" do
    it "raises NotImplementedError naming the class that failed to implement it" do
      adapter_class = declared_adapter

      expect { adapter_class.new.default_configuration }
        .to raise_error(NotImplementedError, /#{Regexp.escape(adapter_class.inspect)} must implement/)
    end

    it "names the method, so an adapter author is told which half is missing" do
      expect { declared_adapter.new.default_configuration }
        .to raise_error(NotImplementedError, /must implement #default_configuration/)
    end
  end

  describe "#reading" do
    before { stub_const("FictionalClient", Module.new) }

    it "reports a value that differs from the client's own default as configured, carrying both" do
      adapter = reading_adapter(live: config(request_timeout: 45), pristine: config)

      expect(adapter.reading(:request_timeout))
        .to have_attributes(client: :fixture_client, setting: :request_timeout,
                            value: 45, default: 300, state: :configured)
    end

    it "derives the default from the client rather than from a literal, so an upstream change is reported" do
      adapter = reading_adapter(live: config(request_timeout: 45), pristine: config(request_timeout: 120))

      expect(adapter.reading(:request_timeout)).to have_attributes(value: 45, default: 120)
    end

    it "reports a live nil as configured, because an app that set no timeout at all has chosen one" do
      adapter = reading_adapter(live: config(request_timeout: nil), pristine: config)

      expect(adapter.reading(:request_timeout))
        .to have_attributes(value: nil, default: 300, state: :configured)
      expect(adapter.reading(:request_timeout)).to be_determined
    end

    it "reports a value equal to the client's own default as defaulted, with no value the app chose" do
      adapter = reading_adapter(live: config, pristine: config)

      expect(adapter.reading(:request_timeout))
        .to have_attributes(value: nil, default: 300, state: :defaulted)
    end

    it "reports a defaulted reading as undetermined, because the app cannot be shown to have chosen it" do
      expect(reading_adapter(live: config, pristine: config).reading(:max_retries)).to be_undetermined
    end

    it "reports a setting mapped to nil as unsupported: the ruby-openai case, a client with no retry setting" do
      adapter = reading_adapter(live: config, pristine: config,
                                settings: { request_timeout: :request_timeout, max_retries: nil })

      expect(adapter.reading(:max_retries))
        .to have_attributes(setting: :max_retries, value: nil, default: nil, state: :unsupported)
    end

    it "counts that unsupported reading as determined, because a client that ships no such setting is a fact" do
      adapter = reading_adapter(live: config, pristine: config,
                                settings: { request_timeout: :request_timeout, max_retries: nil })

      expect(adapter.reading(:max_retries)).to be_determined
    end

    it "refuses a setting outside the vocabulary, which only our own caller could ask for, rather than " \
       "answering the confident unsupported it has no evidence for" do
      expect { reading_adapter(live: config, pristine: config).reading(:temperature) }
        .to raise_error(ArgumentError, "setting must be one of [:request_timeout, :max_retries], got :temperature")
    end

    it "refuses it before asking the host whether the client is even loaded, so a typo reads the same either way" do
      hide_const("FictionalClient")

      expect { reading_adapter(live: config, pristine: config).reading(:temperature) }
        .to raise_error(ArgumentError, /got :temperature/)
    end

    it "keeps the leniency that has a subject: a declared nil is still unsupported and never raises" do
      adapter = reading_adapter(live: config, pristine: config,
                                settings: { request_timeout: :request_timeout, max_retries: nil })

      expect { adapter.reading(:max_retries) }.not_to raise_error
      expect(adapter.reading(:max_retries)).to have_attributes(state: :unsupported)
    end

    it "reports absent for every canonical setting when the client is not loaded" do
      hide_const("FictionalClient")
      adapter = reading_adapter(live: config, pristine: config)

      expect(described_class::SETTINGS.map { |setting| adapter.reading(setting).state })
        .to eq(%i[absent absent])
    end

    it "reports an absent reading as undetermined, so an unloaded gem never reads as a confident OK" do
      hide_const("FictionalClient")

      expect(reading_adapter(live: config, pristine: config).reading(:request_timeout)).to be_undetermined
    end

    it "returns absent without touching a configuration that would raise, so a missing client cannot abort the audit" do
      hide_const("FictionalClient")
      adapter_class = declared_adapter
      adapter_class.define_method(:configuration) { raise "the client is not here" }

      expect(adapter_class.new.reading(:request_timeout)).to have_attributes(state: :absent, value: nil)
    end

    it "asks detection before support, so an adapter for an absent gem makes no confident claim about it" do
      hide_const("FictionalClient")
      adapter = reading_adapter(live: config, pristine: config,
                                settings: { request_timeout: :request_timeout, max_retries: nil })

      expect(adapter.reading(:max_retries)).to have_attributes(state: :absent)
      expect(adapter.reading(:max_retries)).to be_undetermined
    end

    it "reads absent through a path rooted at a non-module, so a host constant sitting on the namespace root " \
       "is one more unloaded client rather than an exception out of the audit" do
      stub_const("Brand", "acme")
      adapter = reading_adapter(live: config, pristine: config, client_constant: "Brand::Client")

      expect(adapter.readings.values.map(&:state)).to eq(%i[absent absent])
      expect(adapter.readings.values).to all(be_undetermined)
    end

    it "reports unreadable when the live object no longer exposes the mapped accessor, so API drift is not a pass" do
      drifted = Data.define(:timeout_seconds).new(timeout_seconds: 45)
      adapter = reading_adapter(live: drifted, pristine: config)

      expect(adapter.reading(:request_timeout))
        .to have_attributes(value: nil, default: nil, state: :unreadable)
    end

    it "reports unreadable rather than a value when the client answers only through method_missing" do
      permissive = Class.new do
        def method_missing(*) = 999
        def respond_to_missing?(*) = false
      end.new
      adapter = reading_adapter(live: permissive, pristine: config)

      expect(adapter.reading(:request_timeout))
        .to have_attributes(value: nil, default: nil, state: :unreadable)
    end

    it "reports unreadable when the client itself raises, and does not itself raise" do
      exploding = Class.new { def request_timeout = raise("the client blew up") }.new
      adapter = reading_adapter(live: exploding, pristine: config)

      expect { adapter.reading(:request_timeout) }.not_to raise_error
      expect(adapter.reading(:request_timeout)).to have_attributes(state: :unreadable)
    end

    it "reports an unreadable reading as undetermined, so client drift surfaces instead of passing silently" do
      exploding = Class.new { def request_timeout = raise("the client blew up") }.new

      expect(reading_adapter(live: exploding, pristine: config).reading(:request_timeout)).to be_undetermined
    end

    describe "through an armed autoload the host cannot resolve" do
      let(:adapter) { autoloading_adapter }

      before { Object.autoload(:UnloadableClient, "no_such_file_llm_audit_spec") }
      after { Object.send(:remove_const, :UnloadableClient) }

      it "still looks present to detection, which is what makes the client readers reachable at all" do
        expect(adapter).to be_detected
      end

      it "reports unreadable rather than raising, because the LoadError const_get fires is a ScriptError and " \
         "would otherwise pass straight through the rescue around the client readers" do
        expect { adapter.reading(:request_timeout) }.not_to raise_error
        expect(adapter.reading(:request_timeout))
          .to have_attributes(state: :unreadable, value: nil, default: nil)
      end

      it "reports it as undetermined, so a client the host could not load never reads as a confident OK" do
        expect(adapter.reading(:request_timeout)).to be_undetermined
      end

      it "still answers for every canonical setting, which is what a whole-manifest sweep depends on" do
        expect { adapter.readings }.not_to raise_error
        expect(adapter.readings.values.map(&:state)).to eq(%i[unreadable unreadable])
      end

      it "is not a vacuous witness: that LoadError really is outside the StandardError the rescue names" do
        expect { Object.const_get("UnloadableClient") }.to raise_error(LoadError)
        expect(LoadError.ancestors).to include(ScriptError)
        expect(LoadError <= StandardError).to be_nil
      end
    end

    it "keeps our own construction bugs loud: an adapter that never declared its client still raises" do
      expect { Class.new(described_class).new.reading(:request_timeout) }
        .to raise_error(LlmAudit::Error, /did not declare its metadata/)
    end

    it "does not launder a NotImplementedError: a declared adapter with no reader stays loud" do
      adapter_class = declared_adapter

      expect { adapter_class.new.reading(:request_timeout) }
        .to raise_error(NotImplementedError, /must implement #configuration/)
    end

    it "stamps the adapter's own id on every reading, so a reading is attributable to one client" do
      adapter = reading_adapter(live: config(request_timeout: 45), pristine: config, id: :other_client)

      expect(adapter.readings.values.map(&:client)).to eq(%i[other_client other_client])
    end

    it "has no parameter through which an adapter could attribute a reading to another client" do
      expect(described_class.instance_method(:reading).parameters.map(&:last)).to eq([:setting])
    end
  end

  describe "#readings" do
    before { stub_const("FictionalClient", Module.new) }

    it "answers one reading per canonical setting, keyed and ordered by the canonical vocabulary" do
      adapter = reading_adapter(live: config(request_timeout: 45), pristine: config)

      expect(adapter.readings.keys).to eq(described_class::SETTINGS)
      expect(adapter.readings.values.map(&:setting)).to eq(described_class::SETTINGS)
    end

    it "asks every setting the same question, so a client's second setting is never silently skipped" do
      adapter = reading_adapter(live: config(request_timeout: 45, max_retries: 5), pristine: config)

      expect(adapter.readings.values.map(&:state)).to eq(%i[configured configured])
      expect(adapter.readings.values.map(&:value)).to eq([45, 5])
    end

    it "still answers for every setting when the client is not loaded" do
      hide_const("FictionalClient")
      adapter = reading_adapter(live: config, pristine: config)

      expect(adapter.readings.values.map(&:state)).to eq(%i[absent absent])
      expect(adapter.readings.values).to all(be_undetermined)
    end
  end

  describe "the extension point" do
    it "adds a client in one subclass - a declaration and two readers - without touching Base" do
      stub_const("Fictional", Module.new)
      stub_const("Fictional::Configuration", config_class)
      stub_const("Fictional::CONFIG", config_class.new(request_timeout: 45, max_retries: 3))

      adapter_class = Class.new(described_class) do
        declare id: :fictional, gem_name: "fictional-ai", client_constant: "Fictional",
                settings: { request_timeout: :request_timeout, max_retries: nil }

        def configuration = client_module::CONFIG
        def default_configuration = client_module::Configuration.new(request_timeout: 300, max_retries: 3)
      end

      expect(adapter_class.instance_methods(false)).to contain_exactly(:configuration, :default_configuration)
      expect(adapter_class.new.readings.values.map { |reading| [reading.setting, reading.state, reading.value] })
        .to eq([[:request_timeout, :configured, 45], [:max_retries, :unsupported, nil]])
    end

    it "reaches its client through #client_module, so an adapter never has to name a constant twice" do
      stub_const("Fictional", Module.new)
      adapter_class = declared_adapter(client_constant: "Fictional")

      expect(adapter_class.new.send(:client_module)).to be(Fictional)
    end

    it "spells that helper apart from Reading#client, so the id a reading carries is not the client itself" do
      stub_const("Fictional", Module.new)
      adapter = reading_adapter(live: config, pristine: config, client_constant: "Fictional")

      expect(adapter.send(:client_module)).to be(Fictional)
      expect(adapter.reading(:request_timeout).client).to eq(:fixture_client)
    end

    it "reports a path rooted at a non-module as the NameError this contract documents, so an adapter author " \
       "reaching for the client directly is told the one thing that happened: it could not be resolved" do
      stub_const("Brand", "acme")
      adapter = declared_adapter(client_constant: "Brand::Client").new

      expect { adapter.send(:client_module) }.to raise_error(NameError, /Brand::Client could not be resolved/)
    end

    describe "reaching a client the host cannot load" do
      let(:adapter) { declared_adapter(client_constant: "UnloadableClient").new }

      before { Object.autoload(:UnloadableClient, "no_such_file_llm_audit_spec") }
      after { Object.send(:remove_const, :UnloadableClient) }

      it "reports the same NameError rather than the LoadError, which is what lets the rescue around the " \
         "client readers stay tight enough to keep NotImplementedError loud" do
        expect { adapter.send(:client_module) }
          .to raise_error(NameError, /UnloadableClient could not be resolved/)
      end

      it "keeps the LoadError as the cause, so nobody is told the constant was merely missing" do
        expect { adapter.send(:client_module) }
          .to raise_error(NameError) { |error| expect(error.cause).to be_a(LoadError) }
      end
    end

    it "defines nothing on Base that a new client would have to reopen" do
      expect(described_class.instance_methods(false))
        .to contain_exactly(:detected?, :readings, :reading, :configuration, :default_configuration)
    end

    it "adds no constant to Base for a new client, so the vocabulary stays client-independent" do
      expect(described_class.constants).to contain_exactly(:SETTINGS, :Metadata)
    end
  end
end
