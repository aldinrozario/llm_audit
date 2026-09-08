# frozen_string_literal: true

require "open3"

# The one spec file whose subject is the absent path - the adapter's and the check's - on the client-absent
# CI leg (gemfiles/no_llm_gems.gemfile), and the reason that leg is not vacuous: every other spec file that
# loads the client does it through spec/support/ruby_llm_client.rb and is therefore in that leg's
# --exclude-pattern, while this one is deliberately not - so this is the only file that keeps asserting that
# path when the client is genuinely not installed rather than merely not required.
# spec/tasks/llm_audit_doctor_spec.rb reaches the same verdict end-to-end, through the formatter, and is not
# excluded either; what is only here is the reading-by-reading account underneath that verdict.
# Requiring spec/support/ruby_llm_client.rb from here - directly, or by including the "with a pristine
# RubyLLM configuration" context it defines - would turn that leg into `0 examples, 1 error`, because the
# LoadError fires at file-load time and RSpec cannot filter around it. No pristine-config context is
# needed: Base#reading returns an absent Reading before it ever reaches the client's configuration.
# spec/ci/declared_floors_spec.rb reddens the DEFAULT leg if either half of that ever drifts. The `ruby`
# helper below duplicates spec/llm_audit_spec.rb's deliberately: a shared spec/support/ file would be one
# more require edge that could grow a client require, and that guard reads the `_client` requires of
# *_spec.rb files - a support file reaching a client through ANOTHER support file would leave it green
# while this leg dies with a LoadError.
RSpec.describe "the client-absent path" do
  subject(:adapter) { LlmAudit::Adapters::RubyLlm.new }

  def ruby(script)
    lib = File.expand_path("../../../lib", __dir__)
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-I", lib, "-e", script)
    [stdout, status.exitstatus, stderr]
  end

  # hide_const is a no-op on the leg where the client is genuinely uninstalled, and the fake on every other
  # leg: these three examples therefore describe one behaviour in both worlds, which is what makes moving
  # them here worth more than leaving them stubbed in ruby_llm_spec.rb.
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

  # The check's own absent path, and legal in this file for the same reason the adapter's is: Base#reading
  # answers absent before it ever resolves the client constant, so the shipped check reaches this verdict
  # without the client being installed and this file still requires none. It runs the real manifest rather
  # than a fabricated adapter - fabricating one is request_timeout_spec.rb's job - because what is proved
  # here is that the check a doctor run would execute reports absence instead of a passing timeout.
  describe "the request timeout check with no client loaded" do
    before { hide_const("RubyLLM") }

    it "reports the client absent and undetermined, never a passing timeout" do
      findings = LlmAudit::Checks::RequestTimeout.new.call

      expect(findings.map { |finding| [finding.check_id, finding.severity] })
        .to eq([%i[request_timeout undetermined]])
      expect(findings.first.message).to include("ruby_llm client is not loaded")
    end
  end

  # Half of a pair whose other half stays in spec/llm_audit_spec.rb: only a process that has loaded the
  # client can show that a process which loads it WOULD see the constant, which is what stops this example
  # from passing vacuously - and that half therefore cannot run on the leg where the gem is uninstalled.
  # hide_const cannot clear $LOADED_FEATURES, so neither half can be an in-process double. The readings
  # ride along with detected? deliberately: on the client-present legs this is the only process in the
  # suite that reads the adapter's own readings with the client genuinely absent - the doctor-task
  # subprocess reaches an adapter too, but only through a rendered finding - so the readers are shown
  # reporting absence here or nowhere. They are reached through the public manifest, the way a check will
  # reach them.
  it "never loads the client gem: the adapter reports it absent in a process that has not required it" do
    script = 'require "llm_audit"; ' \
             "print [defined?(RubyLLM), LlmAudit::Adapters::RubyLlm.new.detected?, " \
             "LlmAudit.adapters.flat_map { |a| a.new.readings.values.map(&:state) }].inspect"
    stdout, exitstatus, stderr = ruby(script)

    expect([stdout, exitstatus]).to eq(["[nil, false, [:absent, :absent]]", 0]), (stderr unless stderr.empty?)
  end

  # The check half of that pair, and the only run in the suite that reads the shipped check's own findings
  # with a client that is not installed at all on EVERY leg. Three other in-process runs reach that same
  # absence - the hide_const block above, request_timeout_spec.rb's manifest example, and
  # stdout_invariant_spec.rb's per-check loop - but the last two only on the client-absent leg itself, where
  # the gem is uninstalled for everyone, and the first through a hide_const that fakes it everywhere else.
  # The doctor-task subprocess meets a real absence on every leg too, but reads it as a formatted line.
  # Here there is nothing to fake on any leg, since no leg requires the client into this subprocess. The
  # check is built the way Doctor builds one - no arguments, so the real manifest supplies the adapters - and
  # asked for its findings directly, so what stdout carries is the verdict and nothing a formatter added.
  # The message is asserted because the severity alone cannot tell the two undetermined branches apart: drop
  # Base#reading's `unless detected?` guard and the NameError from resolving the constant is swallowed by
  # #client_values' rescue, which reads as :unreadable and reports undetermined too. Only NOT_LOADED says
  # "is not loaded"; NOT_READ says the client "is loaded but".
  it "never loads the client gem: the check reports it undetermined in a process that has not required it" do
    script = 'require "llm_audit"; ' \
             "print LlmAudit::Checks::RequestTimeout.new.call" \
             '.map { |f| [f.check_id, f.severity, f.message.include?("is not loaded")] }.inspect'
    stdout, exitstatus, stderr = ruby(script)

    expect([stdout, exitstatus]).to eq(["[[:request_timeout, :undetermined, true]]", 0]), (stderr unless stderr.empty?)
  end
end
