# frozen_string_literal: true

module LlmAudit
  module Formatters
    class Terminal
      NO_FINDINGS = "llm_audit: no findings"

      def call(findings)
        raise ArgumentError, "findings must be enumerable, got nil" if findings.nil?

        findings = findings.to_a
        return NO_FINDINGS if findings.empty?

        [summary(findings.size), *findings.map { |finding| render(finding) }].join("\n\n")
      end

      private

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
