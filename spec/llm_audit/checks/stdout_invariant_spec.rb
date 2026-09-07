# frozen_string_literal: true

require "ripper"

RSpec.describe "the no-stdout invariant" do
  let(:lib_directory) { File.expand_path("../../../lib", __dir__) }
  let(:single_writer) { File.join(lib_directory, "llm_audit", "doctor.rb") }
  let(:scanned_files) { Dir.glob(File.join(lib_directory, "**", "*.rb")) - [single_writer] }
  let(:check_files) { Dir.glob(File.join(lib_directory, "llm_audit", "checks", "**", "*.rb")) }
  let(:non_code_tokens) { %i[on_tstring_content on_comment on_embdoc] }
  let(:output_primitive) { /\A(?:puts|print|printf|pp|warn|display|\$stdout|\$stderr|\$>|STDOUT|STDERR)\z/ }
  let(:offences) { offences_in(scanned_files) }

  def offences_in(paths)
    paths.flat_map { |path| offences_in_file(path) }
  end

  def offences_in_file(path)
    lines = File.readlines(path)
    tokens = Ripper.lex(lines.join).reject { |(_, type, _, _)| non_code_tokens.include?(type) }
    offending = tokens.filter_map { |((number, _), _, token, _)| number if token.match?(output_primitive) }

    offending.uniq.map { |number| "#{path}:#{number}: #{lines[number - 1].strip}" }
  end

  describe "the gem sources" do
    it "are found by the scan, so a broken glob cannot pass vacuously" do
      expect(scanned_files).not_to be_empty
    end

    it "exclude Doctor, which does name one, so a stale exclusion cannot make the scan inert" do
      expect(offences_in([single_writer])).not_to be_empty
    end

    it "name no output primitive outside Doctor" do
      expect(offences).to be_empty, <<~MESSAGE
        A check must return Findings and let a formatter do the printing; Doctor is the only writer.
        Output primitives found:
        #{offences.join("\n")}
      MESSAGE
    end
  end

  describe "the check sources" do
    it "are all registered, so the generative guard cannot iterate an empty registry" do
      expect(LlmAudit.registry.ids.size).to eq(check_files.count { |path| File.basename(path) != "base.rb" })
    end
  end

  LlmAudit.registry.each do |check|
    describe "the #{check.id} check, run for real" do
      it "writes nothing to stdout" do
        expect { check.new.call }.not_to output.to_stdout_from_any_process
      end

      it "writes nothing to stderr" do
        expect { check.new.call }.not_to output.to_stderr_from_any_process
      end

      it "returns nothing but Findings, collected the one way Doctor collects them" do
        registry = LlmAudit::Registry.new.tap { |target| target.register(check) }
        findings = LlmAudit::Doctor.new(registry: registry).findings

        expect(findings).to all(be_a(LlmAudit::Finding))
        expect(findings).to eq(check.new.call), "a registered check must not lean on Doctor's coercion"
      end
    end
  end
end
