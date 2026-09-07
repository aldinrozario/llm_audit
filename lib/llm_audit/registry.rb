# frozen_string_literal: true

module LlmAudit
  class Registry
    class DuplicateIdError < Error; end
    class UnknownIdError < Error; end

    include Enumerable

    def initialize
      @checks = {}
    end

    def register(check)
      id = check.id
      raise ArgumentError, "#{check.inspect} has no id" if id.nil?

      if (existing = @checks[id])
        raise DuplicateIdError,
              "check id #{id.inspect} is already registered to #{existing.inspect}; " \
              "#{check.inspect} cannot claim it"
      end

      @checks[id] = check
    end

    def [](id)
      @checks[id]
    end

    def fetch(id)
      @checks.fetch(id) { raise UnknownIdError, "no check registered under #{id.inspect}" }
    end

    def each(&block)
      return @checks.each_value unless block

      @checks.each_value(&block)
      self
    end

    def ids
      @checks.keys
    end
  end
end
