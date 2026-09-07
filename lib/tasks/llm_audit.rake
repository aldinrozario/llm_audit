# frozen_string_literal: true

namespace :llm_audit do
  desc "Audit this app's LLM client configuration for security and reliability risks"
  task :doctor do
    LlmAudit::Doctor.new.run
  end
end
