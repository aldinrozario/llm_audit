# frozen_string_literal: true

RSpec.describe LlmAudit::Registry do
  def check_class(id, label: "Check_#{id}")
    Class.new do
      define_singleton_method(:id) { id }
      define_singleton_method(:inspect) { label }
    end
  end

  subject(:registry) { described_class.new }

  let(:timeout_check) { check_class(:request_timeout) }
  let(:retry_check) { check_class(:missing_retry) }

  describe "the error classes" do
    it "lets a caller rescue either failure as LlmAudit::Error" do
      expect(described_class::DuplicateIdError.ancestors).to include(LlmAudit::Error)
      expect(described_class::UnknownIdError.ancestors).to include(LlmAudit::Error)
    end
  end

  describe "#register" do
    it "returns the check it registered" do
      expect(registry.register(timeout_check)).to be(timeout_check)
    end

    it "stores the check itself, never an instance of it" do
      registry.register(timeout_check)

      expect(registry[:request_timeout]).to be(timeout_check)
    end

    it "accepts anything answering to .id, without reaching for metadata" do
      expect(timeout_check).not_to respond_to(:metadata)
      expect { registry.register(timeout_check) }.not_to raise_error
    end

    it "rejects a check whose id is nil rather than storing it under a nil key" do
      idless = check_class(nil, label: "IdlessCheck")

      expect { registry.register(idless) }.to raise_error(ArgumentError, /IdlessCheck has no id/)
      expect(registry.ids).to be_empty
    end
  end

  describe "#register with an id that is already taken" do
    let(:claimant) { check_class(:request_timeout, label: "ClaimantCheck") }

    before { registry.register(timeout_check) }

    it "rejects the second registration" do
      expect { registry.register(claimant) }.to raise_error(described_class::DuplicateIdError)
    end

    it "names the contested id and the incumbent holding it" do
      expect { registry.register(claimant) }
        .to raise_error(described_class::DuplicateIdError,
                        /:request_timeout is already registered to Check_request_timeout/)
    end

    it "names the claimant that was turned away" do
      expect { registry.register(claimant) }
        .to raise_error(described_class::DuplicateIdError, /ClaimantCheck cannot claim it/)
    end

    it "leaves the first registration in place" do
      expect { registry.register(claimant) }.to raise_error(described_class::DuplicateIdError)

      expect(registry[:request_timeout]).to be(timeout_check)
    end

    it "does not grow the registry" do
      expect { registry.register(claimant) }.to raise_error(described_class::DuplicateIdError)

      expect(registry.count).to eq(1)
    end

    it "rejects the incumbent re-registering itself, so registering twice is never silent" do
      expect { registry.register(timeout_check) }
        .to raise_error(described_class::DuplicateIdError, /Check_request_timeout cannot claim it/)
    end
  end

  describe "#[]" do
    it "returns the check registered under the id" do
      registry.register(timeout_check)

      expect(registry[:request_timeout]).to be(timeout_check)
    end

    it "returns nil for an unregistered id" do
      expect(registry[:nope]).to be_nil
    end
  end

  describe "#fetch" do
    it "returns the check registered under the id" do
      registry.register(timeout_check)

      expect(registry.fetch(:request_timeout)).to be(timeout_check)
    end

    it "raises UnknownIdError naming the id for an unregistered id" do
      expect { registry.fetch(:nope) }
        .to raise_error(described_class::UnknownIdError, /no check registered under :nope/)
    end
  end

  describe "#ids" do
    it "is empty for a fresh registry" do
      expect(registry.ids).to be_empty
    end

    it "lists the registered ids in registration order" do
      registry.register(timeout_check)
      registry.register(retry_check)

      expect(registry.ids).to eq(%i[request_timeout missing_retry])
    end

    it "reflects checks registered after an earlier call" do
      registry.register(timeout_check)
      registry.ids

      registry.register(retry_check)

      expect(registry.ids).to eq(%i[request_timeout missing_retry])
    end
  end

  describe "enumeration" do
    before do
      registry.register(timeout_check)
      registry.register(retry_check)
    end

    it "yields the checks themselves, in registration order" do
      expect(registry.to_a).to eq([timeout_check, retry_check])
    end

    it "supports the Enumerable surface" do
      expect(registry.map(&:id)).to eq(%i[request_timeout missing_retry])
      expect(registry.count).to eq(2)
    end

    it "returns an enumerator over the checks when each is called without a block" do
      expect(registry.each).to be_a(Enumerator)
      expect(registry.each.to_a).to eq([timeout_check, retry_check])
    end

    it "returns the registry itself when a block is given, never the internal store" do
      yielded = []

      expect(registry.each { |check| yielded << check }).to be(registry)
      expect(yielded).to eq([timeout_check, retry_check])
    end
  end

  describe "two registries" do
    it "keeps their checks separate" do
      registry.register(timeout_check)

      expect(described_class.new.ids).to be_empty
    end

    it "lets the same id be registered in each" do
      registry.register(timeout_check)

      expect { described_class.new.register(check_class(:request_timeout)) }.not_to raise_error
    end
  end
end
