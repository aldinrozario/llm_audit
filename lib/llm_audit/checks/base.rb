# frozen_string_literal: true

module LlmAudit
  module Checks
    class Base
      Metadata = Data.define(:id, :default_severity, :owasp_reference) do
        def initialize(id:, default_severity:, owasp_reference:, **)
          raise ArgumentError, "id must be a Symbol, got #{id.inspect}" unless id.is_a?(Symbol)
          unless Severity.declarable?(default_severity)
            raise ArgumentError, "default_severity must be one of #{Severity::LEVELS.inspect}, " \
                                 "got #{default_severity.inspect}"
          end
          unless Finding.valid_text?(owasp_reference)
            raise ArgumentError, "owasp_reference must be a non-empty String, " \
                                 "got #{owasp_reference.inspect}"
          end

          super
        end
      end

      class << self
        def declare(id:, default_severity:, owasp_reference:)
          raise Error, "#{inspect} already declared its metadata as #{@metadata.inspect}" if @metadata

          @metadata = Metadata.new(id: id, default_severity: default_severity,
                                   owasp_reference: owasp_reference)
        end
        private :declare

        def metadata
          @metadata || raise(Error, "#{inspect} did not declare its metadata")
        end

        def id = metadata.id
        def default_severity = metadata.default_severity
        def owasp_reference = metadata.owasp_reference
      end

      # Takes the manifest's adapter CLASSES and hands the check instances, one per adapter per check - Doctor
      # builds a fresh check per registry entry, so the memo is not shared across checks. An adapter memoizes
      # the client configuration it read, so a check that built a second instance would rebuild the pristine
      # configuration it compares against, which expands paths and reads ENV. Every argument is defaulted
      # because Doctor builds a check with none, and LlmAudit.adapters is read here rather than at load time
      # so that requiring this file ahead of the manifest stays load-order safe.
      def initialize(adapters: LlmAudit.adapters)
        @adapter_classes = adapters
      end

      # Returns this check's Findings, and nothing else: it never prints, and it reports a value it
      # could not read as #undetermined rather than omitting it. Doctor is the single point that
      # coerces the return value, so a check with nothing to report may return []. Nothing downstream
      # of Doctor repeats that leniency - Formatters::Terminal requires a real collection.
      def call
        raise NotImplementedError, "#{self.class.inspect} must implement #call"
      end

      private

      def adapters = @adapters ||= @adapter_classes.map(&:new)

      def finding(location:, message:, remediation:, severity: self.class.default_severity)
        unless Severity.declarable?(severity)
          raise ArgumentError, "severity must be one of #{Severity::LEVELS.inspect}, got " \
                               "#{severity.inspect}; use #undetermined for a value that could not be read"
        end

        Finding.new(check_id: self.class.id, severity: severity, location: location,
                    message: message, remediation: remediation,
                    owasp_reference: self.class.owasp_reference)
      end

      def undetermined(location:, message:, remediation:)
        Finding.undetermined(check_id: self.class.id, location: location, message: message,
                             remediation: remediation, owasp_reference: self.class.owasp_reference)
      end
    end
  end
end
