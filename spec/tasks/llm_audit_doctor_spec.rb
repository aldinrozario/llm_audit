# frozen_string_literal: true

require "open3"
require_relative "../support/rails_host"

RSpec.describe "rake llm_audit:doctor" do
  subject(:task) { Rake::Task["llm_audit:doctor"] }

  after { task.reenable }

  it "is listed by rake -T with a one-line description" do
    expect(task.comment).to eq("Audit this app's LLM client configuration for security and reliability risks")
  end

  it "prints the registered check's finding through the terminal formatter" do
    expected = a_string_including("llm_audit: 1 finding")
               .and(a_string_including("[INFO] scaffold:"))
               .and(a_string_including("owasp:"))
               .and(a_string_including("LLM10:2025 Unbounded Consumption"))

    expect { task.invoke }.to output(expected).to_stdout
  end

  describe "the documented standalone probe" do
    it "boots the Rails host and runs the task in a fresh process" do
      stdout, stderr, status = Open3.capture3(
        RbConfig.ruby, "-I", File.expand_path("../../lib", __dir__), "-I", File.expand_path("..", __dir__),
        "-e", 'require "support/rails_host"; Rake::Task["llm_audit:doctor"].invoke'
      )

      expect([stdout, status.exitstatus])
        .to match([a_string_including("llm_audit: 1 finding"), 0]), (stderr unless stderr.empty?)
    end
  end
end
