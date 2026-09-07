# frozen_string_literal: true

module LlmAudit
  module Adapters
    Reading = Data.define(:client, :setting, :value, :default, :state)

    class Reading
      CONFIGURED  = :configured   # the app demonstrably set this value
      DEFAULTED   = :defaulted    # the client's own default is in effect; the app cannot be shown to have chosen it
      UNSUPPORTED = :unsupported  # this client ships no such setting - not applicable, not unknown
      ABSENT      = :absent       # the client gem is not loaded in this process
      UNREADABLE  = :unreadable   # the client is loaded but the value could not be obtained (API drift)

      STATES = [CONFIGURED, DEFAULTED, UNSUPPORTED, ABSENT, UNREADABLE].freeze
      DETERMINED_STATES = [CONFIGURED, UNSUPPORTED].freeze
      DEFAULT_BEARING_STATES = [CONFIGURED, DEFAULTED].freeze

      class << self
        def configured(client:, setting:, value:, default:)
          new(client: client, setting: setting, value: value, default: default, state: CONFIGURED)
        end

        def defaulted(client:, setting:, default:)
          new(client: client, setting: setting, value: nil, default: default, state: DEFAULTED)
        end

        def unsupported(client:, setting:)
          new(client: client, setting: setting, value: nil, default: nil, state: UNSUPPORTED)
        end

        def absent(client:, setting:)
          new(client: client, setting: setting, value: nil, default: nil, state: ABSENT)
        end

        def unreadable(client:, setting:)
          new(client: client, setting: setting, value: nil, default: nil, state: UNREADABLE)
        end

        # Public because Base::Metadata validates its own symbols against it. The adapter layer may not reach
        # across to Finding.valid_text?, but that is no licence to speak two vocabularies inside itself: an
        # id, a setting and an accessor are all the same kind of thing, checked in the same one place.
        def valid_symbol?(value) = value.is_a?(Symbol)
      end

      def initialize(client:, setting:, value:, default:, state:)
        validate_symbol(:client, client)
        validate_symbol(:setting, setting)
        validate_state(state)
        validate_value(state, value)
        validate_default(state, default)

        super
      end

      # Data#with only routes through a custom initialize from Ruby 3.3; the gem supports 3.2.
      def with(**overrides)
        return self if overrides.empty?

        self.class.new(**to_h, **overrides)
      end

      def configured? = state == CONFIGURED
      def determined? = DETERMINED_STATES.include?(state)
      def undetermined? = !determined?

      private

      def validate_symbol(field, symbol)
        return if self.class.valid_symbol?(symbol)

        raise ArgumentError, "#{field} must be a Symbol, got #{symbol.inspect}"
      end

      def validate_state(state)
        return if STATES.include?(state)

        raise ArgumentError, "state must be one of #{STATES.inspect}, got #{state.inspect}"
      end

      # A configured reading may carry nil, and that is the point: an app that set request_timeout = nil
      # chose *no* timeout - a value it picked, not one we failed to read. Treating nil as unknown would
      # report the single most dangerous real configuration as unreadable.
      def validate_value(state, value)
        return if state == CONFIGURED || value.nil?

        raise ArgumentError, "a reading in state #{state.inspect} carries no value, got #{value.inspect}"
      end

      def validate_default(state, default)
        return if DEFAULT_BEARING_STATES.include?(state) || default.nil?

        raise ArgumentError, "a reading in state #{state.inspect} carries no default, got #{default.inspect}"
      end
    end
  end
end
