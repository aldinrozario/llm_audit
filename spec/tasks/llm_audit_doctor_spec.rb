# frozen_string_literal: true

require_relative "../support/rails_host"

RSpec.describe "rake llm_audit:doctor" do
  subject(:task) { Rake::Task["llm_audit:doctor"] }

  after { task.reenable }

  it "is listed by rake -T with a one-line description" do
    expect(task.comment).to eq("Audit this app's LLM client configuration for security and reliability risks")
  end

  it "prints no checks registered" do
    expect { task.invoke }.to output("no checks registered\n").to_stdout
  end
end
