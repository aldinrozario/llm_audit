# frozen_string_literal: true

module LlmAudit
  class Railtie < ::Rails::Railtie
    rake_tasks do
      load File.expand_path("../tasks/llm_audit.rake", __dir__)
    end
  end
end
