# frozen_string_literal: true

require_relative "llm_audit/version"
require_relative "llm_audit/severity"
require_relative "llm_audit/finding"

module LlmAudit
  class Error < StandardError; end
end

require_relative "llm_audit/railtie" if defined?(Rails::Railtie)
