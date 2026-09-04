# frozen_string_literal: true

require_relative "llm_audit/version"

module LlmAudit
  class Error < StandardError; end
end

require_relative "llm_audit/railtie" if defined?(Rails::Railtie)
