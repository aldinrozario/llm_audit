# frozen_string_literal: true

require "open3"
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
