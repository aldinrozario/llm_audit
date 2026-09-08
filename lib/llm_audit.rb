# frozen_string_literal: true

require_relative "llm_audit/version"
require_relative "llm_audit/error"
require_relative "llm_audit/severity"
require_relative "llm_audit/finding"
require_relative "llm_audit/registry"
require_relative "llm_audit/adapters/reading"
require_relative "llm_audit/adapters/base"
require_relative "llm_audit/adapters/ruby_llm"
require_relative "llm_audit/checks/base"
require_relative "llm_audit/checks/request_timeout"
require_relative "llm_audit/formatters/terminal"
require_relative "llm_audit/doctor"

module LlmAudit
  def self.registry
    @registry ||= Registry.new.tap { |registry| registry.register(Checks::RequestTimeout) }
  end

  # A frozen manifest rather than a Registry: the only operations a consumer needs are enumerate and select, and
  # an adapter reaching Doctor's registry would be `call`ed as though it were a check. Not Base.subclasses
  # either - the anonymous subclasses the specs build linger there until GC and would pollute the list.
  def self.adapters
    @adapters ||= [Adapters::RubyLlm].freeze
  end
end

require_relative "llm_audit/railtie" if defined?(Rails::Railtie)
