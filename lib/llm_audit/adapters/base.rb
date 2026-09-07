# frozen_string_literal: true

module LlmAudit
  module Adapters
    class Base
      SETTINGS = %i[request_timeout max_retries].freeze

      Metadata = Data.define(:id, :gem_name, :client_constant, :settings)

      class Metadata
        CONSTANT_NAME = /\A[A-Z]\w*(?:::[A-Z]\w*)*\z/

        def initialize(id:, gem_name:, client_constant:, settings:)
          validate_symbol(:id, id)
          validate_text(:gem_name, gem_name)
          validate_constant_name(client_constant)
          validate_settings(settings)

          super(id: id, gem_name: gem_name, client_constant: client_constant, settings: settings.dup.freeze)
        end

        def accessor_for(setting) = settings[setting]

        # Data#with only routes through a custom initialize from Ruby 3.3; the gem supports 3.2.
        def with(**overrides)
          return self if overrides.empty?

          self.class.new(**to_h, **overrides)
        end

        private

        def validate_symbol(field, symbol)
          return if Reading.valid_symbol?(symbol)

          raise ArgumentError, "#{field} must be a Symbol, got #{symbol.inspect}"
        end

        def validate_text(field, text)
          return if text.is_a?(String) && !text.strip.empty?

          raise ArgumentError, "#{field} must be a non-empty String, got #{text.inspect}"
        end

        def validate_constant_name(client_constant)
          return if client_constant.is_a?(String) && client_constant.match?(CONSTANT_NAME)

          raise ArgumentError, "client_constant must be a constant name, got #{client_constant.inspect}"
        end

        # Exactly the canonical keys, never a subset: an omitted setting is an oversight, while an explicit
        # nil is a decision that this client ships no such setting. Adding a canonical setting therefore makes
        # every adapter answer yes-or-no at load time instead of quietly reading as not applicable.
        def validate_settings(settings)
          raise ArgumentError, "settings must be a Hash, got #{settings.inspect}" unless settings.is_a?(Hash)

          unless settings.keys.sort == SETTINGS.sort
            raise ArgumentError, "settings must map exactly #{SETTINGS.inspect}, got #{settings.keys.inspect}"
          end

          settings.each { |setting, accessor| validate_accessor(setting, accessor) }
        end

        def validate_accessor(setting, accessor)
          return if accessor.nil? || Reading.valid_symbol?(accessor)

          raise ArgumentError, "the #{setting.inspect} accessor must be a Symbol or nil, " \
                               "got #{accessor.inspect}"
        end
      end

      class << self
        def declare(id:, gem_name:, client_constant:, settings:)
          raise Error, "#{inspect} already declared its metadata as #{@metadata.inspect}" if @metadata

          @metadata = Metadata.new(id: id, gem_name: gem_name, client_constant: client_constant,
                                   settings: settings)
        end
        private :declare

        def metadata
          @metadata || raise(Error, "#{inspect} did not declare its metadata")
        end

        def id = metadata.id
        def gem_name = metadata.gem_name
        def client_constant = metadata.client_constant
        def accessor_for(setting) = metadata.accessor_for(setting)
      end

      # Deliberately not memoized, at any scope, and concrete here so all adapters inherit the same answer:
      # this is an observation of the host process's load state, not a computed value. A warmed memo would go
      # on reporting a client the adapter can no longer see, and would let the gem-absent examples pass
      # without the detector ever detecting absence (and `@x ||= false` never memoizes anyway).
      # const_defined? triggers no autoload the way const_get would, and the false skips Object's ancestors,
      # so a constant that happens to hang off Kernel cannot be mistaken for the client. It raises TypeError
      # rather than answering when the declared path cannot be walked at all - Metadata accepts namespaced
      # names, so a host constant is free to occupy the root with something that is not a module - and a path
      # Ruby cannot walk names no client this process has loaded. That is false, and never an exception
      # escaping the one question every check asks first.
      def detected?
        Object.const_defined?(self.class.client_constant, false)
      rescue TypeError
        false
      end

      def readings = SETTINGS.to_h { |setting| [setting, reading(setting)] }

      # Detection is asked before support, and never the other way round: a Reading is a statement about this
      # app, so an adapter for a gem that is not loaded must say absent rather than report a confident
      # "this client has no such setting" about a client that is not there. A setting outside the canonical
      # vocabulary can only have come from our own caller and never from a client, and there is no evidence
      # behind calling it unsupported - which is a determined state - so it raises instead. The leniency that
      # has a real subject, a client that genuinely ships no such setting, is the declared nil below.
      def reading(setting)
        validate_setting(setting)
        return Reading.absent(client: self.class.id, setting: setting) unless detected?

        accessor = self.class.accessor_for(setting)
        return Reading.unsupported(client: self.class.id, setting: setting) if accessor.nil?

        compare(setting, accessor)
      end

      # The extension point. Adding a client gem is one new file - a subclass that declares its id, gem name,
      # client constant and the accessor each canonical setting maps to, then implements these two readers -
      # and Base is never reopened for it. Reach the client itself through the private #client_module and
      # never by naming its constant a second time: client_constant stays the one place the client's identity
      # is written down, which is what lets the subclass be called RubyLlm without shadowing the RubyLLM it
      # reads. An adapter knows clients, not severities: it returns Readings and never Findings, and it never
      # prints. Nothing the client does, and nothing the host has done to the constant that names it, makes
      # #detected? or #reading raise - a client that cannot be resolved at all is one more value the adapter
      # cannot obtain, and comes back as an undetermined Reading instead of aborting the audit - while a
      # construction bug of our own still does: an adapter that never declared its metadata, never
      # implemented a reader, or a caller that asked for a setting outside SETTINGS.
      # #configuration returns the live object the app runs on; #default_configuration returns a pristine one,
      # which is what makes provenance observable without any adapter hardcoding a default that upstream is
      # free to change. Both are invoked once per canonical setting, so memoize them if building either is not
      # free - RubyLlm does, because Configuration.new expands paths and reads ENV. They are hooks Base calls
      # behind #detected? and they carry none of #reading's guarantees: called directly on a host where the
      # client is not loaded, #configuration raises NameError from the constant lookup. Read a client through
      # #reading or #readings, never through these two.
      def configuration
        raise NotImplementedError, "#{self.class.inspect} must implement #configuration"
      end

      def default_configuration
        raise NotImplementedError, "#{self.class.inspect} must implement #default_configuration"
      end

      private

      def validate_setting(setting)
        return if SETTINGS.include?(setting)

        raise ArgumentError, "setting must be one of #{SETTINGS.inspect}, got #{setting.inspect}"
      end

      # Not memoized either, and for the same reason as #detected?: it is a constant lookup, an observation.
      # const_get is the step that fires an armed autoload, so it fails in two ways a merely missing constant
      # does not: a target the host cannot load raises LoadError - a ScriptError, which passes straight
      # through the deliberately tight rescue below - and a path rooted at a non-module raises TypeError.
      # Neither says anything about the client; both say only that the declared constant could not be
      # resolved, which is already what a NameError from here means. Re-raising them as that one failure is
      # what lets the rescue below stay narrow rather than learn to swallow ScriptError, which is also where
      # NotImplementedError lives.
      def client_module
        Object.const_get(self.class.client_constant)
      rescue LoadError, TypeError => e
        raise NameError, "#{self.class.client_constant} could not be resolved: #{e.message}"
      end

      def compare(setting, accessor)
        pair = client_values(accessor)
        return Reading.unreadable(client: self.class.id, setting: setting) if pair.nil?

        value, default = pair
        return Reading.defaulted(client: self.class.id, setting: setting, default: default) if value == default

        Reading.configured(client: self.class.id, setting: setting, value: value, default: default)
      end

      # Tight on purpose: the rescue wraps the two client readers and nothing else. Drift in a client we do
      # not own comes back as an unreadable reading, while a construction bug of ours - an adapter that never
      # declared its metadata, a Reading built wrong - stays loud instead of arriving dressed as drift.
      def client_values(accessor)
        live = configuration
        pristine = default_configuration
        return unless live.respond_to?(accessor) && pristine.respond_to?(accessor)

        [live.public_send(accessor), pristine.public_send(accessor)]
      rescue StandardError
        nil
      end
    end
  end
end
