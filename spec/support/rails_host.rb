# frozen_string_literal: true

require "rake"
require "rails"
require "llm_audit/railtie"

Class.new(Rails::Application) do
  config.eager_load = false
  config.root = File.expand_path("..", __dir__)
end

Rake.application = Rake::Application.new
Rake::TaskManager.record_task_metadata = true
Rails.application.load_tasks
