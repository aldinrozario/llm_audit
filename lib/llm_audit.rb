# frozen_string_literal: true

require_relative "llm_audit/version"
require_relative "llm_audit/error"
require_relative "llm_audit/severity"
require_relative "llm_audit/finding"
require_relative "llm_audit/registry"
require_relative "llm_audit/checks/base"
require_relative "llm_audit/checks/scaffold"
require_relative "llm_audit/formatters/terminal"
require_relative "llm_audit/doctor"

module LlmAudit
  def self.registry
    @registry ||= Registry.new.tap { |registry| registry.register(Checks::Scaffold) }
  end
end

require_relative "llm_audit/railtie" if defined?(Rails::Railtie)
