# frozen_string_literal: true

require "ripper"

RSpec.describe "the client-object invariant" do
  let(:lib_directory) { File.expand_path("../../lib", __dir__) }
  # Every file this time, the adapters and the rake task included: the objects this scan is about live in the
  # adapters, and the exemption message_invariant_spec grants that layer rests on it never naming Finding,
  # which says nothing about what it may render into a String that a check then carries.
  let(:scanned_files) { Dir.glob(File.join(lib_directory, "**", "*.{rb,rake}")) }
  let(:prose_and_space) { %i[on_comment on_embdoc on_sp on_nl on_ignored_nl on_ignored_sp] }
  let(:call_operators) { [".", "&."] }
  let(:receiver_types) { %i[on_ident on_ivar] }
  # The names a client configuration, or an object holding one, travels under in lib/. Not `check`: in lib/
  # that name is always the check CLASS (registry.rb, doctor.rb), whose inspect is its name.
  let(:client_bearer) do
    /\A@?(?:configuration|default_configuration|config|live|pristine|client|adapter|adapters|facade|connection|conn)\z/
  end
  let(:renderer) { /\A(?:inspect|to_s|pretty_inspect|to_json|as_json)\z/ }
  # format's %p IS inspect: format("%p", warmed_adapter) prints the key, and so does %10p, %-1p, %1$p or
  # %<name>10p - a flag, width or argument position between the % and the p is the same directive. \b so
  # 100%pure is not one.
  let(:inspect_directive) { /%(?:<\w+>)?[-+ 0#\d$.]*(?:<\w+>)?p\b/ }
  let(:offences) { offences_in(scanned_files) }

  def offences_in(paths)
    paths.flat_map { |path| offences_in_source(File.read(path), path) }
  end

  def offences_in_source(source, path)
    lines = source.lines

    offending_lines(code_tokens(source)).map { |number| "#{path}:#{number}: #{lines[number - 1].strip}" }
  end

  # Three passes over one token list: the triple walk sees a send or an interpolation, the pair walk sees a
  # renderer named as a symbol literal, and a string literal is one token neither walk can look inside, so the
  # directive is read off each token on its own.
  def offending_lines(tokens)
    (sent_lines(tokens) + symbol_lines(tokens) + directive_lines(tokens)).uniq.sort
  end

  def sent_lines(tokens)
    tokens.each_cons(3).filter_map do |(first, second, third)|
      first.first.first if rendered?(first, second, third) || interpolated?(first, second, third)
    end
  end

  def symbol_lines(tokens)
    tokens.each_cons(2).filter_map { |(opening, name)| opening.first.first if symbolised?(opening, name) }
  end

  def directive_lines(tokens)
    tokens.filter_map { |token| token.first.first if directive?(token) }
  end

  def rendered?(receiver, operator, reader)
    receiver_types.include?(receiver.fetch(1)) && receiver.fetch(2).match?(client_bearer) &&
      call_operators.include?(operator.fetch(2)) && reader.fetch(2).match?(renderer)
  end

  # A bare "#{adapter}" calls to_s with no send to see: the interpolation brackets are the tokens that give it
  # away.
  def interpolated?(opening, name, closing)
    opening.fetch(1) == :on_embexpr_beg && receiver_types.include?(name.fetch(1)) &&
      name.fetch(2).match?(client_bearer) && closing.fetch(1) == :on_embexpr_end
  end

  # &:inspect, send(:inspect) and method(:inspect) all name the renderer as a symbol literal with no receiver
  # to read, so the symbol itself is what is refused, whatever it is handed to: no file under lib/ has a
  # legitimate use of one today, and a future map(&:to_s) over scalars can be written as a block instead.
  def symbolised?(opening, name)
    opening.fetch(1) == :on_symbeg && name.fetch(1) == :on_ident && name.fetch(2).match?(renderer)
  end

  def directive?(token)
    token.fetch(1) == :on_tstring_content && token.fetch(2).match?(inspect_directive)
  end

  def code_tokens(source)
    Ripper.lex(source).reject { |(_, type, _, _)| prose_and_space.include?(type) }
  end

  describe "the gem sources" do
    it "are found by the scan, adapters and the rake task among them, so a narrowed glob cannot pass vacuously" do
      expect(scanned_files).to include(File.join(lib_directory, "llm_audit", "adapters", "base.rb"),
                                       File.join(lib_directory, "llm_audit", "adapters", "ruby_llm.rb"),
                                       File.join(lib_directory, "llm_audit", "checks", "request_timeout.rb"),
                                       File.join(lib_directory, "llm_audit", "doctor.rb"),
                                       File.join(lib_directory, "tasks", "llm_audit.rake"))
    end

    it "render no client configuration, adapter, facade or connection into text, in any layer" do
      expect(offences).to be_empty, <<~MESSAGE
        A client configuration object's inspect prints every provider key it was given - RubyLLM::Configuration's
        ivar filter does not cover inspect below 2.0, and OpenAI::Configuration has none (gap G33) - and
        Kernel#inspect on a warmed adapter walks into the configuration it memoized. Finding#initialize type-gates
        every field to a String, so an object cannot BE a field; the one way a key reaches a report is a String
        built from that object's inspect, to_s, or a bare interpolation, which is what this scan refuses in every
        file under lib/.
        Renders found:
        #{offences.join("\n")}
      MESSAGE
    end
  end

  describe "what the scan sees" do
    it "catches a render however it is written, so no spelling of it slips past" do
      [%("\#{adapter.inspect}"), "adapter.to_s", "config&.inspect", "live.pretty_inspect", "pristine.to_json",
       "facade.to_json", "conn.as_json", "connection.inspect", "adapters.inspect", "@configuration.inspect",
       "@config.to_s", "@connection&.inspect", "adapter\n  .inspect", "client.inspect",
       "default_configuration.inspect"].each do |source|
        expect(offences_in_source(source, "leak.rb").size).to eq(1), source
      end
    end

    it "catches a bare interpolation, which is to_s by another spelling" do
      [%("\#{configuration}"), %("\#{adapter}"), %("\#{@configuration}"), %("\#{ pristine }"),
       %(raise Error, "bad: \#{default_configuration}")].each do |source|
        expect(offences_in_source(source, "leak.rb").size).to eq(1), source
      end
    end

    it "catches a renderer named as a symbol literal, which is the send by another spelling" do
      ["adapters.map(&:inspect)", "adapter.send(:inspect)", "adapter.public_send(:to_s)",
       "adapter.method(:inspect).call", "adapter.then(&:pretty_inspect)"].each do |source|
        expect(offences_in_source(source, "leak.rb").size).to eq(1), source
      end
    end

    it "catches the inspect format directive, which is inspect by another spelling" do
      [%(format("%<observed>p", observed: value)), %(format("%p", adapter)), %(format("%10p", adapter)),
       %(format("%-1p", adapter)), %(format("%1$p", adapter)),
       %(format("%<observed>-4p", observed: value))].each do |source|
        expect(offences_in_source(source, "leak.rb").size).to eq(1), source
      end
    end

    it "leaves a class name, a declared field and a scalar read alone" do
      ["self.class.inspect", "adapter.class.gem_name", %("\#{adapter.class.gem_name}"), "value.class",
       "client_module.config", "client_module.configuration.request_timeout", "reading.state.inspect",
       "check.inspect", "error.class", "live.public_send(accessor)", "connection.builder.handlers",
       "Rails.env.to_s", "environment.inspect", "@configuration ||= client_module.config",
       "Reading.absent(client: self.class.id, setting: setting)", %("100%pure"), %("%<environment>s"),
       "client_module::Client.new.send(:conn)", "@adapter_classes.map(&:new)",
       "finding.severity.to_s.upcase"].each do |source|
        expect(offences_in_source(source, "fine.rb")).to be_empty, source
      end
    end

    it "leaves prose alone, so the comment stating the rule is not what enforces it" do
      expect(offences_in_source("# never adapter.inspect into a message", "fine.rb")).to be_empty
      expect(offences_in_source(%("the configuration object's inspect prints every token"), "fine.rb")).to be_empty
    end
  end
end
