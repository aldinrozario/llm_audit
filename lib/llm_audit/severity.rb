# frozen_string_literal: true

module LlmAudit
  module Severity
    UNDETERMINED = :undetermined
    LEVELS = %i[error warning info].freeze
    ALL = [*LEVELS, UNDETERMINED].freeze

    def self.valid?(value)
      ALL.include?(value)
    end

    def self.declarable?(value)
      LEVELS.include?(value)
    end

    def self.undetermined?(value)
      value == UNDETERMINED
    end
  end
end
