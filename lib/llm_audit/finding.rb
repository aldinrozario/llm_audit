# frozen_string_literal: true

module LlmAudit
  Finding = Data.define(:check_id, :severity, :location, :message, :remediation, :owasp_reference)

  class Finding
    CONFIG_LOCATION = :config
    SYMBOLIC_LOCATIONS = [CONFIG_LOCATION].freeze
    TEXT_FIELDS = %i[message remediation owasp_reference].freeze

    def self.undetermined(check_id:, location:, message:, remediation:, owasp_reference:)
      new(check_id: check_id, severity: Severity::UNDETERMINED, location: location,
          message: message, remediation: remediation, owasp_reference: owasp_reference)
    end

    def initialize(check_id:, severity:, location:, **text)
      raise ArgumentError, "check_id must be a Symbol, got #{check_id.inspect}" unless check_id.is_a?(Symbol)
      unless Severity.valid?(severity)
        raise ArgumentError, "severity must be one of #{Severity::ALL.inspect}, got #{severity.inspect}"
      end
      unless self.class.valid_location?(location)
        raise ArgumentError, "location must be a non-empty String or one of " \
                             "#{SYMBOLIC_LOCATIONS.inspect}, got #{location.inspect}"
      end
      validate_text_fields(text)

      super
    end

    def self.valid_location?(value)
      SYMBOLIC_LOCATIONS.include?(value) || valid_text?(value)
    end

    def self.valid_text?(value)
      value.is_a?(String) && !value.strip.empty?
    end

    # Data#with only routes through a custom initialize from Ruby 3.3; the gem supports 3.2.
    def with(**overrides)
      return self if overrides.empty?

      self.class.new(**to_h, **overrides)
    end

    def symbolic_location?
      SYMBOLIC_LOCATIONS.include?(location)
    end

    def undetermined?
      Severity.undetermined?(severity)
    end

    private

    def validate_text_fields(text)
      TEXT_FIELDS.each do |field|
        next unless text.key?(field)

        value = text[field]
        next if self.class.valid_text?(value)

        raise ArgumentError, "#{field} must be a non-empty String, got #{value.inspect}"
      end
    end
  end
end
