# frozen_string_literal: true

RSpec.describe LlmAudit::Severity do
  describe "the vocabulary" do
    it "declares the levels a check may choose, ordered most to least urgent" do
      expect(described_class::LEVELS).to eq(%i[error warning info])
    end

    it "adds undetermined to the levels a finding may carry" do
      expect(described_class::ALL).to eq(%i[error warning info undetermined])
    end

    it "freezes both collections" do
      expect(described_class::LEVELS).to be_frozen
      expect(described_class::ALL).to be_frozen
    end
  end

  describe ".valid?" do
    it "accepts every declarable level" do
      expect(described_class::LEVELS).to all(satisfy { |level| described_class.valid?(level) })
    end

    it "accepts undetermined" do
      expect(described_class.valid?(described_class::UNDETERMINED)).to be true
    end

    it "rejects an unknown symbol" do
      expect(described_class.valid?(:critical)).to be false
    end

    it "rejects the string form of a level" do
      expect(described_class.valid?("error")).to be false
    end

    it "rejects nil" do
      expect(described_class.valid?(nil)).to be false
    end
  end

  describe ".declarable?" do
    it "accepts every declarable level" do
      expect(described_class::LEVELS).to all(satisfy { |level| described_class.declarable?(level) })
    end

    it "rejects undetermined, so no check may declare or select it - see Checks::Base#finding" do
      expect(described_class.declarable?(described_class::UNDETERMINED)).to be false
    end

    it "rejects an unknown symbol" do
      expect(described_class.declarable?(:critical)).to be false
    end
  end

  describe ".undetermined?" do
    it "is true for undetermined" do
      expect(described_class.undetermined?(described_class::UNDETERMINED)).to be true
    end

    it "is false for a declarable level" do
      expect(described_class.undetermined?(:error)).to be false
    end
  end
end
