# frozen_string_literal: true

module LlmAudit
  module Checks
    class Scaffold < Base
      declare id: :scaffold,
              default_severity: :info,
              owasp_reference: "LLM10:2025 Unbounded Consumption"

      def call
        [
          finding(
            location: Finding::CONFIG_LOCATION,
            message: "scaffolding finding - the seam works end to end; no app configuration was inspected",
            remediation: "Nothing to fix. Issue #4 replaces this check with the request-timeout check."
          )
        ]
      end
    end
  end
end
