# frozen_string_literal: true

require "open3"
require "stringio"
require_relative "support/ruby_llm_client"
require_relative "support/ruby_openai_client"

RSpec.describe LlmAudit do
  it "has a version number" do
    expect(LlmAudit::VERSION).not_to be nil
  end

  describe ".registry" do
    it "memoizes one gem-wide registry" do
      expect(LlmAudit.registry).to be(LlmAudit.registry)
    end

    it "seeds it with the consumption checks, in the order the report prints them" do
      expect(LlmAudit.registry.ids).to eq(%i[request_timeout max_retries max_output_tokens])
      expect(LlmAudit.registry[:request_timeout]).to be(LlmAudit::Checks::RequestTimeout)
      expect(LlmAudit.registry[:max_retries]).to be(LlmAudit::Checks::MaxRetries)
      expect(LlmAudit.registry[:max_output_tokens]).to be(LlmAudit::Checks::MaxOutputTokens)
    end

    # The band each check lands on against the real clients is pinned here and nowhere else: every check spec
    # fabricates its adapters so it can run on the client-absent leg, and this file is already excluded there.
    # A ruby_llm host on its defaults reads :defaulted for the timeout and the retries - 300s is over the
    # timeout's limit, 3 retries is at the retry limit - so one is a :warning and the other the :info a
    # within-limit default earns; and :unsupported for the output-token cap, which that check grades at its
    # own :warning because an uncapped response is a cost and not a not-applicable. A ruby-openai host on its
    # defaults reads :defaulted 120s for the timeout, over the limit, so a :warning too; :unsupported for the
    # retries, because a stock install carries no retry middleware and so retries nothing - the :info
    # no-retries finding, which is where that check has teeth; and :unsupported for the cap, the same
    # :warning. None is silent, and the count the doctor task pins depends on that. AC10: all three
    # consumption checks report against ruby_llm; GH-6 AC7: and against ruby-openai.
    describe "each seeded check, run against the real clients" do
      include_context "with a pristine RubyLLM configuration"
      include_context "with a pristine OpenAI configuration"

      it "reports once per adapter, at the band each client on its defaults deserves" do
        bands = LlmAudit.registry.to_h { |check| [check.id, check.new.call.map(&:severity)] }

        expect(bands).to eq(request_timeout: %i[warning warning], max_retries: %i[info info],
                            max_output_tokens: %i[warning warning])
      end

      it "gives the missing-retry check its teeth against ruby-openai on its defaults: an :info finding that " \
         "the client never retries, never a pass" do
        findings = LlmAudit::Checks::MaxRetries.new(adapters: [LlmAudit::Adapters::RubyOpenai]).call

        expect(findings.map(&:severity)).to eq([:info])
        expect(findings.first.message).to include("ruby-openai client ships no retry setting")
      end

      it "reports the uncapped :warning against ruby-openai, never undetermined" do
        findings = LlmAudit::Checks::MaxOutputTokens.new(adapters: [LlmAudit::Adapters::RubyOpenai]).call

        expect(findings.map(&:severity)).to eq([:warning])
        expect(findings.first.message).to include("ships no global output-token cap")
      end
    end
  end

  describe ".adapters" do
    it "memoizes one gem-wide list" do
      expect(LlmAudit.adapters).to be(LlmAudit.adapters)
    end

    it "is frozen, so a caller cannot bolt an adapter on at runtime" do
      expect(LlmAudit.adapters).to be_frozen
    end

    it "holds the ruby_llm and ruby-openai adapters, in the order the report lists them" do
      expect(LlmAudit.adapters).to eq([LlmAudit::Adapters::RubyLlm, LlmAudit::Adapters::RubyOpenai])
    end

    it "holds only adapters, so nothing here can be mistaken for a check the Doctor would call" do
      expect(LlmAudit.adapters).to all(be < LlmAudit::Adapters::Base)
    end

    it "gives every adapter a distinct id, since a Reading is attributed by id and nothing else" do
      ids = LlmAudit.adapters.map(&:id)

      expect(ids).to eq(ids.uniq)
    end

    # The manifest is hand-written, which is the price of not having a registry, and this is the compensating
    # control: an adapter file that is required and specced but never listed would be skipped by every
    # consumer in silence. Counting files mirrors the registry's own completeness guard in
    # spec/llm_audit/checks/stdout_invariant_spec.rb.
    it "lists every adapter file, so an adapter cannot ship unreachable" do
      files = Dir.glob(File.expand_path("../lib/llm_audit/adapters/*.rb", __dir__))
                 .reject { |path| %w[base.rb reading.rb].include?(File.basename(path)) }

      expect(files).not_to be_empty
      expect(LlmAudit.adapters.size).to eq(files.size)
    end

    # AC9's runtime half, driven off the manifest rather than written once per adapter. Its static half is
    # the Ripper scan in stdout_invariant_spec, which globs all of lib/ and needs no edit for a new adapter;
    # this loop is what makes a new adapter's silence generative too. Both client contexts are included
    # because reading either adapter materialises that client's process-global config, and the
    # spec/support/*_client.rb files are the one documented way to touch them - a fresh global happens to
    # equal a pristine one, so nothing reddens without this today, but that is a coincidence and not a
    # contract.
    LlmAudit.adapters.each do |adapter|
      describe "the #{adapter.id} adapter, run for real" do
        include_context "with a pristine RubyLLM configuration"
        include_context "with a pristine OpenAI configuration"

        it "answers for every canonical setting, so the two silence examples below are not vacuous" do
          expect(adapter.new.readings.keys).to eq(LlmAudit::Adapters::Base::SETTINGS)
        end

        it "writes nothing to stdout while reading a real client's configuration" do
          expect { adapter.new.readings }.not_to output.to_stdout_from_any_process
        end

        it "writes nothing to stderr, so a debug warn cannot creep into an adapter" do
          expect { adapter.new.readings }.not_to output.to_stderr_from_any_process
        end
      end
    end
  end

  # GH-7 AC3/AC4/AC6, at the level a user sees: a whole Doctor run over both real clients. "Undetermined
  # without credentials" holds vacuously in M1 - no reading in this vocabulary needs a key (ruby_llm's config is
  # a plain object; ruby-openai 8.3.0's Client.new does not raise without a token, and the token never reaches
  # the connection the adapter walks) - so it is pinned rather than built: the cross-check proves a determined
  # severity appears exactly where the adapter's reading was readable, the differential proves a credential
  # changes no verdict, and the degrade example pins the one credential-gated shape (ruby-openai below 7.0).
  # The sentinel examples are G33's positive control, live because the assay examples show the same run would
  # have printed the sentinel through a formatter that inspected the ruby-openai configuration - and ruby_llm's
  # below 2.0, where Configuration#inspect still fell through to Kernel#inspect. Both pristine contexts
  # are included because every example here materialises both process-global configs, and the sentinel ones
  # mutate them.
  describe "Doctor, run against the real clients" do
    include_context "with a pristine RubyLLM configuration"
    include_context "with a pristine OpenAI configuration"

    let(:sentinel) { "sk-SENTINEL-DO-NOT-LEAK-0123" }
    let(:expected_count) { LlmAudit.registry.ids.size * LlmAudit.adapters.size }
    let(:unread) { [LlmAudit::Adapters::Reading::ABSENT, LlmAudit::Adapters::Reading::UNREADABLE] }
    # Every option a credential travels under on either configuration, read off each client's own option list
    # rather than named one by one, so a provider added upstream is covered the day it lands.
    let(:credential) { /(?:_key|_token)\z/ }
    let(:ruby_llm_credentials) { RubyLLM::Configuration.options.grep(credential) }
    let(:ruby_openai_credentials) { RubyOpenaiConfigIsolation.options.grep(credential) }

    def run_doctor(environment: "test")
      io = StringIO.new
      doctor = LlmAudit::Doctor.new(io: io, environment: environment)
      doctor.run
      [doctor.findings, io.string]
    end

    def credential_every_client
      ruby_llm_credentials.each { |option| RubyLLM.config.public_send(:"#{option}=", sentinel) }
      ruby_openai_credentials.each { |option| OpenAI.configuration.public_send(:"#{option}=", sentinel) }
    end

    def text_of(findings)
      findings.flat_map { |finding| finding.to_h.values.map(&:to_s) }.join("\n")
    end

    # What a formatter that rendered the configuration itself would print - the leak the sentinel examples
    # exist to rule out, run through Doctor so the whole path is the real one.
    def inspected(configuration)
      io = StringIO.new
      LlmAudit::Doctor.new(formatter: ->(_findings, **) { configuration.inspect }, io: io).run
      io.string
    end

    # One entry per (check, adapter) - which holds because the pristine contexts leave every reading on the
    # client's own default and no check is silent on a default (each check's #graded returns nil only for a
    # value the app chose, inside the limit), not because Doctor promises it; a :configured within-limit
    # reading would drop its entry and misalign the map, which is what the count example above reports first.
    # In the order Doctor#findings produces them: the registry in registration order, and within each check
    # the adapters in manifest order.
    def unread_map
      LlmAudit.registry.flat_map do |check|
        LlmAudit.adapters.map { |adapter| unread.include?(adapter.new.reading(check::SETTING).state) }
      end
    end

    it "starts with every credential on both clients unset, so the examples below audit a host with none" do
      expect(ruby_llm_credentials).not_to be_empty
      expect(ruby_openai_credentials).not_to be_empty
      expect(ruby_llm_credentials.map { |option| RubyLLM.config.public_send(option) }).to all(be_nil)
      expect(ruby_openai_credentials.map { |option| OpenAI.configuration.public_send(option) }).to all(be_nil)
      expect(RubyLlmConfigIsolation.leaked_options(RubyLLM.config)).to be_empty
      expect(RubyOpenaiConfigIsolation.leaked_options(OpenAI.configuration)).to be_empty
    end

    it "reports one finding per check per adapter with no credential in the process, omitting none" do
      findings, = run_doctor

      expect(findings.size).to eq(expected_count)
      expect(findings.map(&:message)).not_to include(a_string_including("did not finish"))
    end

    it "reports undetermined exactly where the adapter could not read, and a determined severity nowhere else" do
      findings, = run_doctor

      expect(findings.map(&:undetermined?)).to eq(unread_map)
    end

    # On today's clients every reading reads, so the map above is all false and a check that graded an
    # unreadable reading would not flip it. This leg puts one unreadable reading in play (ruby-openai below 7.0
    # raises at Client.new without a token, the shape spec/llm_audit/adapters/ruby_openai_spec.rb pins) and
    # asks the same question, so the cross-check is shown live rather than assumed so.
    it "lines up the same way once a reading is unreadable, so the cross-check is not vacuous on a host where " \
       "every reading reads" do
      allow(OpenAI::Client).to receive(:new).and_raise(OpenAI::ConfigurationError)
      findings, = run_doctor

      expect(unread_map).to include(true)
      expect(findings.map(&:undetermined?)).to eq(unread_map)
    end

    # Reddens the day an adapter's reading becomes credential-gated, which is a conscious vocabulary decision
    # and not one to discover from a report.
    it "changes no verdict when every credential is set: no reading in this vocabulary is gated on one" do
      bare, = run_doctor
      credential_every_client
      keyed, = run_doctor

      expect(keyed).to eq(bare)
    end

    it "degrades to undetermined, never a pass, on the one shape that does need a token: a ruby-openai client " \
       "that will not build" do
      allow(OpenAI::Client).to receive(:new).and_raise(OpenAI::ConfigurationError)
      findings, printed = run_doctor

      expect(findings.size).to eq(expected_count)
      expect(printed).to include("[UNDETERMINED] max_retries: the ruby-openai client is loaded but its retry " \
                                 "count could not be read")
      expect(printed).to match(/\[WARNING\] request_timeout: the ruby-openai client runs on the client's own default/)
      expect(findings.select(&:undetermined?).map(&:check_id)).to eq([:max_retries])
    end

    # G33's upstream premise, and what makes the two sentinel examples below live: a formatter that did
    # inspect the configuration would print the key. ruby-openai's OpenAI::Configuration falls through to
    # Kernel#inspect, which prints every ivar, so this leg is the positive control.
    it "would print the sentinel through a formatter that inspected the ruby-openai configuration, so the " \
       "assertions below are live" do
      credential_every_client

      expect(inspected(OpenAI.configuration)).to include(sentinel)
    end

    # ruby_llm closed its half of G33 in 2.0: RubyLLM::Configuration#inspect redacts, where 1.x fell through
    # to Kernel#inspect. Pinned by version rather than dropped, because the gem has no runtime dependency on
    # ruby_llm and a host on 1.x still carries the leak the scan in
    # spec/llm_audit/client_object_invariant_spec.rb guards against. The readback comes first on both
    # branches: from 2.0 the assay is a negative, and a negative proves nothing about a key that was never
    # stored.
    it "would print the sentinel through a formatter that inspected the ruby_llm configuration below 2.0, " \
       "and not from 2.0, where Configuration#inspect redacts" do
      credential_every_client
      inspect_owner = RubyLLM::Configuration.instance_method(:inspect).owner

      expect(ruby_llm_credentials.map { |option| RubyLLM.config.public_send(option) }).to all(eq(sentinel))
      if Gem::Version.new(RubyLLM::VERSION) >= Gem::Version.new("2.0")
        expect(inspect_owner).to eq(RubyLLM::Configuration)
        expect(inspected(RubyLLM.config)).not_to include(sentinel)
      else
        expect(inspect_owner).to eq(Kernel)
        expect(inspected(RubyLLM.config)).to include(sentinel)
      end
    end

    it "prints a sentinel key from neither client's configuration, in any field of any finding" do
      credential_every_client
      findings, printed = run_doctor

      expect(findings.size).to eq(expected_count)
      expect(printed).not_to include(sentinel)
      expect(text_of(findings)).not_to include(sentinel)
    end

    it "keeps it out of a development report too" do
      credential_every_client
      findings, printed = run_doctor(environment: "development")

      expect(printed).to include(LlmAudit::Formatters::Terminal::DEVELOPMENT_WARNING)
      expect(printed).not_to include(sentinel)
      expect(text_of(findings)).not_to include(sentinel)
    end
  end

  describe "requiring the gem" do
    def ruby(script)
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), "-e", script)
      [stdout, status.exitstatus, stderr]
    end

    it "loads the Railtie when Rails is already loaded" do
      script = 'require "rails"; require "llm_audit"; print defined?(LlmAudit::Railtie)'
      stdout, exitstatus, stderr = ruby(script)

      expect([stdout, exitstatus]).to eq(["constant", 0]), (stderr unless stderr.empty?)
    end

    it "loads neither Rails nor the Railtie outside Rails" do
      script = 'require "llm_audit"; print [defined?(Rails), defined?(LlmAudit::Railtie)].inspect'
      stdout, exitstatus, stderr = ruby(script)

      expect([stdout, exitstatus]).to eq(["[nil, nil]", 0]), (stderr unless stderr.empty?)
    end

    it "loads the Finding and check seam and seeds the registry with no Rails present" do
      script = 'require "llm_audit"; print [LlmAudit::Finding, LlmAudit::Checks::Base, LlmAudit.registry.ids].inspect'
      stdout, exitstatus, stderr = ruby(script)

      seam = "[LlmAudit::Finding, LlmAudit::Checks::Base, [:request_timeout, :max_retries, :max_output_tokens]]"
      expect([stdout, exitstatus]).to eq([seam, 0]), (stderr unless stderr.empty?)
    end

    # Half of a pair whose other half is spec/llm_audit/adapters/client_absent_spec.rb - the only spec file
    # that exercises the absent path on the client-absent CI leg, since every spec file that requires the
    # client is excluded there. This half stays here because it can only be true where the gem is
    # installed: it proves that a process which DOES load the client would have shown the constant, which is
    # what stops the absent-path example over there from passing vacuously. hide_const cannot clear
    # $LOADED_FEATURES, so neither half can be replaced by an in-process double.
    it "can require ruby_llm from a bare process, so the client-absent example is not vacuous" do
      script = 'require "ruby_llm"; print defined?(RubyLLM)'
      stdout, exitstatus, stderr = ruby(script)

      expect([stdout, exitstatus]).to eq(["constant", 0]), (stderr unless stderr.empty?)
    end

    it "can require ruby-openai from a bare process, under its own require name, so the client-absent " \
       "example is not vacuous for it either" do
      script = 'require "openai"; print defined?(OpenAI::Configuration)'
      stdout, exitstatus, stderr = ruby(script)

      expect([stdout, exitstatus]).to eq(["constant", 0]), (stderr unless stderr.empty?)
    end
  end
end
