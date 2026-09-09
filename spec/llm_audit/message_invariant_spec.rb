# frozen_string_literal: true

require "ripper"

RSpec.describe "the error-message invariant" do
  let(:lib_directory) { File.expand_path("../../lib", __dir__) }
  let(:adapter_files) { Dir.glob(File.join(lib_directory, "llm_audit", "adapters", "**", "*.rb")) }
  # .rake is in this glob and in neither older source scan: lib/tasks/llm_audit.rake is the file that wraps
  # Doctor#run, so a `rescue => e` written there would repeat a message with nothing else watching it.
  let(:scanned_files) { Dir.glob(File.join(lib_directory, "**", "*.{rb,rake}")) - adapter_files }
  let(:prose_and_space) { %i[on_comment on_embdoc on_sp on_nl on_ignored_nl on_ignored_sp] }
  let(:call_operators) { [".", "&."] }
  # Matched by name rather than by tracing a `rescue => e` binding, because Doctor hands its rescued error to
  # `degraded(check, error)` - a plain parameter, and the one place in the gem where the leak would happen.
  let(:rescued_name) { /\A(?:e|ex|err|error|exception|\$!|\$ERROR_INFO)\z/ }
  # #full_message and #detailed_message embed #message verbatim, and an error's #to_s and #inspect are it.
  let(:message_reader) { /\A(?:message|full_message|detailed_message|to_s|inspect)\z/ }
  let(:offences) { offences_in(scanned_files) }

  def offences_in(paths)
    paths.flat_map { |path| offences_in_source(File.read(path), path) }
  end

  def offences_in_source(source, path)
    lines = source.lines
    numbers = code_tokens(source).each_cons(3).filter_map do |(receiver, operator, reader)|
      receiver.first.first if leaking?(receiver.fetch(2), operator.fetch(2), reader.fetch(2))
    end

    numbers.uniq.map { |number| "#{path}:#{number}: #{lines[number - 1].strip}" }
  end

  def leaking?(receiver, operator, reader)
    receiver.match?(rescued_name) && call_operators.include?(operator) && reader.match?(message_reader)
  end

  def code_tokens(source)
    Ripper.lex(source).reject { |(_, type, _, _)| prose_and_space.include?(type) }
  end

  describe "the gem sources" do
    it "are found by the scan, so a broken glob cannot pass vacuously" do
      expect(scanned_files).not_to be_empty
      expect(scanned_files).to include(File.join(lib_directory, "llm_audit", "doctor.rb"),
                                       File.join(lib_directory, "tasks", "llm_audit.rake"))
    end

    # The adapter layer is out of scope on a principle rather than to spare it: it may not name Finding at
    # all - spec/llm_audit/adapters/undetermined_invariant_spec.rb is what makes that true - so no message it
    # reads can reach a report. Its one interpolation re-raises a const_get failure, whose message is Ruby's
    # own constant-resolution text and never an object's inspect. That it is still found when scanned is what
    # proves both halves live: the scan sees this send in real source, and the exclusion is not stale.
    it "exclude the adapter layer, which does name one, so neither the scan nor the exclusion is inert" do
      expect(adapter_files).not_to be_empty
      expect(scanned_files & adapter_files).to be_empty
      expect(offences_in(adapter_files)).not_to be_empty
    end

    it "repeat no error's own message, in any layer that can build a Finding" do
      expect(offences).to be_empty, <<~MESSAGE
        A degraded Finding carries the error's class and the frame it raised at, never its message. On Ruby
        3.2 - a supported floor and a live CI leg - NoMethodError#message interpolates receiver.inspect, and
        a client configuration object holds every provider API key it was given, so the error most likely to
        arrive here is exactly the one that would print a key into the audit report (gap G37).
        Error messages read:
        #{offences.join("\n")}
      MESSAGE
    end
  end

  describe "what the scan sees" do
    it "catches the interpolation that would put a message into a report" do
      offences = offences_in_source(%(raise Error, "could not read: \#{e.message}"), "leak.rb")

      expect(offences).to eq(["leak.rb:1: raise Error, \"could not read: \#{e.message}\""])
    end

    it "catches the send however it is written, so no spelling of it slips past" do
      %w[error.message e&.message exception.full_message err.detailed_message ex.to_s error.inspect]
        .each { |source| expect(offences_in_source(source, "leak.rb")).not_to be_empty }

      expect(offences_in_source("e\n  .message", "leak.rb")).not_to be_empty
    end

    it "leaves the Finding's own message alone, in either the reader or the keyword" do
      expect(offences_in_source("finding.message", "fine.rb")).to be_empty
      expect(offences_in_source("Finding.undetermined(message: text)", "fine.rb")).to be_empty
      expect(offences_in_source("def rendered(adapter, value, message, remediation)", "fine.rb")).to be_empty
    end

    it "leaves the error's other readers alone, the class and the frame being what a Finding may carry" do
      expect(offences_in_source("format(RAISED, error: error.class)", "fine.rb")).to be_empty
      expect(offences_in_source("error.backtrace&.first", "fine.rb")).to be_empty
    end

    it "leaves prose alone, so the comment stating the rule is not what enforces it" do
      expect(offences_in_source("# Never interpolate error.message.", "fine.rb")).to be_empty
      expect(offences_in_source(%("the error's own message is not repeated here"), "fine.rb")).to be_empty
    end
  end
end
