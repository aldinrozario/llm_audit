# frozen_string_literal: true

module LlmAudit
  class Doctor
    def initialize(registry: LlmAudit.registry, formatter: Formatters::Terminal.new, io: $stdout)
      @registry = registry
      @formatter = formatter
      @io = io
    end

    def run
      io.puts(formatter.call(findings))
      findings
    end

    def findings
      @findings ||= registry.flat_map { |check| Array(check.new.call) }.freeze
    end

    private

    attr_reader :registry, :formatter, :io
  end
end
