# frozen_string_literal: true

require "open3"
require "stringio"
require_relative "../support/rails_host"

RSpec.describe "rake llm_audit:doctor" do
  subject(:task) { Rake::Task["llm_audit:doctor"] }

  after { task.reenable }

  # Doctor resolves its io when it is built, which happens inside the invocation, so swapping $stdout around
  # the invoke is what captures the run. Captured rather than composed into `output`, because what has to be
  # asserted below includes an absence and there is no negative form of a_string_including to `and` onto one.
  def capture_stdout
    original = $stdout
    captured = StringIO.new
    $stdout = captured
    yield
    captured.string
  ensure
    $stdout = original
  end

  # Rails.env is a module-level memo behind a writer, swapped and put back the way spec/support/ruby_llm_client.rb
  # swaps the client's global: the host boots as development, and a developer shell exporting RAILS_ENV would
  # make any example that asserted the environment without a swap flaky.
  def with_rails_env(name)
    original = Rails.instance_variable_get(:@_env)
    Rails.env = name
    yield
  ensure
    Rails.instance_variable_set(:@_env, original)
  end

  it "is listed by rake -T with a one-line description" do
    expect(task.comment).to eq("Audit this app's LLM client configuration for security and reliability risks")
  end

  # The severity band is deliberately not asserted here: this file runs in three worlds that observe three
  # different reading states. In process the clients are loaded, because other spec files require them at
  # load time, so the reading is :defaulted - or :unsupported, for a setting the client ships no accessor
  # for, or that this host wired no retry middleware for; the subprocess below may not require a client at
  # all, so the reading is :absent; and on the client-absent CI leg the whole file sees what that subprocess
  # sees.
  # What holds in all three is that one finding per registered check per listed adapter is printed,
  # attributed to that check, against the symbolic config location and carrying the check's reference. Which
  # band is the check spec's to pin, per state; what this file still pins is that a band was rendered at all,
  # in the formatter's `[BAND] id:` shape - matching the id alone would pass on a formatter that had stopped
  # emitting the line.
  # The count holds in all three worlds only because no registered check falls silent on a client's own
  # default: a within-limit default is :info, never nothing. The absence is the other half: Doctor degrades
  # a raising check to an undetermined finding under that check's own id, at the same config location,
  # carrying the same reference, so every positive assertion here is also satisfied by a check that raised
  # before it read anything. "did not finish" is the one word that tells the two apart - the marker
  # spec/llm_audit/doctor_spec.rb guards its own default run with.
  it "prints one finding per registered check per listed adapter through the terminal formatter" do
    printed = capture_stdout { task.invoke }

    expect(printed).to include("llm_audit: 6 findings", "(config)", "owasp:", "LLM06:2026 Unbounded Consumption")
    expect(printed).to match(/\[[A-Z]+\] request_timeout: /)
    expect(printed).to match(/\[[A-Z]+\] max_retries: /)
    expect(printed).to match(/\[[A-Z]+\] max_output_tokens: /)
    expect(printed).not_to include("did not finish")
  end

  # AC1 and AC2 through the real task: the environment is Rails.env as the host booted it, printed first and
  # never as a finding. Every example swaps the environment explicitly rather than asserting the host's
  # default, which a developer shell exporting RAILS_ENV would change.
  describe "the environment" do
    it "states the environment Rails booted, first, before any finding" do
      printed = with_rails_env("production") { capture_stdout { task.invoke } }

      expect(printed.lines.first).to eq("llm_audit: environment: production\n")
      expect(printed).not_to include(LlmAudit::Formatters::Terminal::DEVELOPMENT_WARNING)
    end

    it "warns on development as a banner line above the six findings, never as a seventh" do
      printed = with_rails_env("development") { capture_stdout { task.invoke } }

      expect(printed.lines[1]).to eq("#{LlmAudit::Formatters::Terminal::DEVELOPMENT_WARNING}\n")
      expect(printed).to include("llm_audit: 6 findings")
      expect(printed.scan(/^\[/).size).to eq(6)
    end

    it "does not warn on test, the AC naming development alone" do
      printed = with_rails_env("test") { capture_stdout { task.invoke } }

      expect(printed.lines.first).to eq("llm_audit: environment: test\n")
      expect(printed).not_to include(LlmAudit::Formatters::Terminal::DEVELOPMENT_WARNING)
    end
  end

  describe "the documented standalone probe" do
    # The host boots without a client gem - support/rails_host.rb may not require one, and the guard in
    # spec/ci/declared_floors_spec.rb keeps it that way - so the reading here is :absent, and both the band
    # and the sentence the check reaches for absence are deterministic on every leg. That is the point worth
    # asserting: a host with no client prints an undetermined finding rather than falling silent and reading
    # as a pass. The band alone would not say it: a check that raised prints [UNDETERMINED] under its own id
    # too, so the absent branch is pinned by its own words and the degraded one is excluded by name.
    # RAILS_ENV is passed to the child explicitly, so the environment line is pinned in a process nothing else
    # touched: the host reads Rails.env, which is that variable, and the task passes it through.
    it "boots the Rails host and runs the task in a fresh process" do
      stdout, stderr, status = Open3.capture3(
        { "RAILS_ENV" => "production" },
        RbConfig.ruby, "-I", File.expand_path("../../lib", __dir__), "-I", File.expand_path("..", __dir__),
        "-e", 'require "support/rails_host"; Rake::Task["llm_audit:doctor"].invoke'
      )

      expect([stdout, status.exitstatus]).to match(
        [a_string_including("llm_audit: environment: production")
          .and(a_string_including("llm_audit: 6 findings"))
          .and(a_string_including("[UNDETERMINED] request_timeout"))
          .and(a_string_including("[UNDETERMINED] max_retries"))
          .and(a_string_including("[UNDETERMINED] max_output_tokens"))
          .and(a_string_including("is not loaded in this process")), 0]
      ), (stderr unless stderr.empty?)
      expect(stdout).not_to include("did not finish"), (stderr unless stderr.empty?)
      expect(stdout).not_to include(LlmAudit::Formatters::Terminal::DEVELOPMENT_WARNING), (stderr unless stderr.empty?)
    end
  end
end
