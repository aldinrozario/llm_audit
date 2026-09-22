# frozen_string_literal: true

module LlmAudit
  module Formatters
    class Terminal
      NO_FINDINGS = "llm_audit: no findings"
      DEVELOPMENT = "development"
      ENVIRONMENT = "llm_audit: environment: %<environment>s"
      UNDETERMINED_ENVIRONMENT = "llm_audit: environment: undetermined - this process did not say which Rails " \
                                 "environment it audited, so which configuration was read cannot be stated; " \
                                 "`rails llm_audit:doctor` states it"
      DEVELOPMENT_WARNING = "llm_audit: warning: the development environment was audited. Client timeouts, " \
                            "retries and caps commonly differ between development and production, so a value " \
                            "read here is no evidence of what production runs on; run this audit where " \
                            "production's configuration loads."

      # The environment is run metadata and never a Finding: rendered above the findings here, and M3's JSON and
      # SARIF siblings take the same keyword as data. nil is a caller that could not say - a Doctor built outside
      # Rails - and reads as undetermined rather than as nothing.
      def call(findings, environment: nil)
        raise ArgumentError, "findings must be enumerable, got nil" if findings.nil?
        unless environment.nil? || Finding.valid_text?(environment)
          raise ArgumentError, "environment must be a non-empty String or nil, got #{environment.inspect}"
        end

        [banner(environment), report(findings.to_a)].join("\n\n")
      end

      private

      # Rails.env is host-controlled free text - RAILS_ENV reaches it verbatim - so it goes through one_line like
      # every other value from outside. Compared to exactly "development": Rails.env.local? would cover test too.
      def banner(environment)
        return UNDETERMINED_ENVIRONMENT if environment.nil?

        lines = [format(ENVIRONMENT, environment: one_line(environment))]
        lines << DEVELOPMENT_WARNING if environment == DEVELOPMENT
        lines.join("\n")
      end

      def report(findings)
        return NO_FINDINGS if findings.empty?

        [summary(findings.size), *findings.map { |finding| render(finding) }].join("\n\n")
      end

      def summary(count)
        "llm_audit: #{count} #{count == 1 ? "finding" : "findings"}"
      end

      def render(finding)
        [
          "[#{finding.severity.to_s.upcase}] #{one_line(finding.check_id)}: #{one_line(finding.message)}",
          "  location:    #{one_line(location(finding))}",
          "  remediation: #{one_line(finding.remediation)}",
          "  owasp:       #{one_line(finding.owasp_reference)}"
        ].join("\n")
      end

      def location(finding)
        finding.symbolic_location? ? "(#{finding.location})" : finding.location
      end

      # Free text reaches the report from host-app config, so a control character in it must not be able
      # to open a second severity band, repaint the line with an ANSI escape, or add the trailing newline
      # Doctor's puts already supplies. Tab and printable UTF-8 can do none of those and survive.
      def one_line(value) = value.to_s.gsub(/\s*[\x00-\x08\x0a-\x1f\x7f]\s*/, " ")
    end
  end
end
