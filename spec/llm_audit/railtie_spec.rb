# frozen_string_literal: true

require_relative "../support/rails_host"

RSpec.describe LlmAudit::Railtie do
  let(:task) { Rake::Task["llm_audit:doctor"] }
  let(:rake_file) { File.expand_path("../../lib/tasks/llm_audit.rake", __dir__) }

  it "is discovered by the host application" do
    expect(Rails.application.railties.map(&:class)).to include(described_class)
  end

  it "defines llm_audit:doctor from lib/tasks/llm_audit.rake exactly once" do
    expect(task.actions.size).to eq(1)
    expect(task.locations).to contain_exactly(start_with(rake_file))
  end
end
