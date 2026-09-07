# frozen_string_literal: true

require "open3"
require_relative "support/ruby_llm_client"

RSpec.describe LlmAudit do
  it "has a version number" do
    expect(LlmAudit::VERSION).not_to be nil
  end

  describe ".registry" do
    it "memoizes one gem-wide registry" do
      expect(LlmAudit.registry).to be(LlmAudit.registry)
    end

    it "seeds it with the scaffold check" do
      expect(LlmAudit.registry[:scaffold]).to be(LlmAudit::Checks::Scaffold)
    end
  end

  describe ".adapters" do
    it "memoizes one gem-wide list" do
      expect(LlmAudit.adapters).to be(LlmAudit.adapters)
    end

    it "is frozen, so a caller cannot bolt an adapter on at runtime" do
      expect(LlmAudit.adapters).to be_frozen
    end

    it "holds the ruby_llm adapter" do
      expect(LlmAudit.adapters).to include(LlmAudit::Adapters::RubyLlm)
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
    # this loop is what makes a new adapter's silence generative too. The RubyLLM context is included because
    # reading the one adapter listed today materialises that client's process-global config, and
    # spec/support/ruby_llm_client.rb is the one documented way to touch it - a fresh global happens to equal
    # a pristine one, so nothing reddens without this today, but that is a coincidence and not a contract.
    LlmAudit.adapters.each do |adapter|
      describe "the #{adapter.id} adapter, run for real" do
        include_context "with a pristine RubyLLM configuration"

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

      seam = "[LlmAudit::Finding, LlmAudit::Checks::Base, [:scaffold]]"
      expect([stdout, exitstatus]).to eq([seam, 0]), (stderr unless stderr.empty?)
    end

    # A pair, and both halves are needed: hide_const cannot clear $LOADED_FEATURES, so only a process that
    # never loaded the client can prove the negative - and only the first example proves that a process which
    # does load it would have shown the constant, which is what stops the second from passing vacuously.
    it "can require ruby_llm from a bare process, so the next example is not vacuous" do
      script = 'require "ruby_llm"; print defined?(RubyLLM)'
      stdout, exitstatus, stderr = ruby(script)

      expect([stdout, exitstatus]).to eq(["constant", 0]), (stderr unless stderr.empty?)
    end

    # The readings ride along with detected? deliberately: this is the only process in the suite where the
    # client is genuinely absent, and hide_const cannot stand in for it, so the readers are shown reporting
    # absence here or nowhere. They are reached through the public manifest, the way a check will reach them.
    it "never loads the client gem: the adapter reports it absent in a process that has not required it" do
      script = 'require "llm_audit"; ' \
               "print [defined?(RubyLLM), LlmAudit::Adapters::RubyLlm.new.detected?, " \
               "LlmAudit.adapters.flat_map { |a| a.new.readings.values.map(&:state) }].inspect"
      stdout, exitstatus, stderr = ruby(script)

      expect([stdout, exitstatus]).to eq(["[nil, false, [:absent, :absent]]", 0]), (stderr unless stderr.empty?)
    end
  end
end
