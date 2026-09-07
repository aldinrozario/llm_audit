# frozen_string_literal: true

require "rake"
require "rails"
# Both requires are load-bearing. "llm_audit" is a no-op under RSpec (spec_helper required it already) but is
# what keeps this file loadable standalone, which the documented QA probe relies on; drop it and the suite
# stays green while the probe dies on `uninitialized constant LlmAudit::Doctor`. "llm_audit/railtie" is needed
# because llm_audit.rb loads the Railtie only when Rails was already loaded, and under RSpec the gem is
# required first (spec_helper, no Rails).
require "llm_audit"
require "llm_audit/railtie"

Class.new(Rails::Application) do
  config.eager_load = false
  config.root = File.expand_path("..", __dir__)
end

Rake.application = Rake::Application.new
Rake::TaskManager.record_task_metadata = true
Rails.application.load_tasks
