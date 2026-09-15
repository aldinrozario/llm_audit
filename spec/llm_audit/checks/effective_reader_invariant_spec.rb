# frozen_string_literal: true

require "ripper"

RSpec.describe "the effective-reader invariant" do
  let(:lib_directory) { File.expand_path("../../../lib", __dir__) }
  let(:check_files) { Dir.glob(File.join(lib_directory, "llm_audit", "checks", "**", "*.rb")) }
  let(:prose_and_space) { %i[on_comment on_embdoc on_sp on_nl on_ignored_nl on_ignored_sp] }
  let(:call_operators) { [".", "&."] }
  # Anchored, so a check's own `default_severity` is left alone. Only `value` and `default` are named because
  # they are the two readers that grade a number on one provenance and nil on the other; `#effective` and
  # every other reader stay legal.
  let(:field_reader) { /\A(?:value|default)\z/ }
  let(:offences) { offences_in(check_files) }

  def offences_in(paths)
    paths.flat_map { |path| offences_in_source(File.read(path), path) }
  end

  def offences_in_source(source, path)
    lines = source.lines
    numbers = code_tokens(source).each_cons(2).filter_map do |(operator, reader)|
      reader.first.first if field_read?(operator.fetch(2), reader.fetch(1), reader.fetch(2))
    end

    numbers.uniq.map { |number| "#{path}:#{number}: #{lines[number - 1].strip}" }
  end

  def field_read?(operator, reader_type, reader)
    call_operators.include?(operator) && reader_type == :on_ident && reader.match?(field_reader)
  end

  def code_tokens(source)
    Ripper.lex(source).reject { |(_, type, _, _)| prose_and_space.include?(type) }
  end

  describe "the check sources" do
    it "are found by the scan, every registered check among them, so a narrowed glob cannot pass vacuously" do
      basenames = check_files.map { |path| File.basename(path, ".rb") }

      expect(basenames).to include("base", *LlmAudit.registry.ids.map(&:to_s))
    end

    it "read a reading through #effective and never as two fields" do
      expect(offences).to be_empty, <<~MESSAGE
        A :defaulted reading carries its number in `default` and hard-sets `value` to nil, so a check that
        reads `.value` on that branch grades a happy client default as unset - a fully rendered wrong verdict,
        not a crash (gap G40). Reading#effective is the one field the state puts a number in; a check that
        dispatches on the state and reads through it cannot hand its grader a nil that was never the value.
        Field reads found:
        #{offences.join("\n")}
      MESSAGE
    end
  end

  describe "what the scan sees" do
    it "catches the pairing however it is written, so no spelling of it slips past" do
      ["reading.value", "reading.default", "reading&.value", "reading\n  .value",
       "graded(adapter, reading.value, :chosen)"].each do |source|
        expect(offences_in_source(source, "leak.rb").size).to eq(1), source
      end
    end

    it "leaves the reader it wants and a check's own locals alone" do
      ["reading.effective", "classify(value)", "self.class.default_severity", "{ value: value, default: 3 }",
       "Adapters::Reading::DEFAULTED"].each do |source|
        expect(offences_in_source(source, "fine.rb")).to be_empty, source
      end
    end

    it "leaves prose alone, so the comment stating the rule is not what enforces it" do
      expect(offences_in_source("# never reading.value on a defaulted branch", "fine.rb")).to be_empty
      expect(offences_in_source(%("the reading.default is the client's own"), "fine.rb")).to be_empty
    end
  end
end
