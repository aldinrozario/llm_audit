# frozen_string_literal: true

require "open3"

RSpec.describe LlmAudit do
  it "has a version number" do
    expect(LlmAudit::VERSION).not_to be nil
  end

  describe "requiring the gem" do
    def ruby(script)
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), "-e", script)
      [stdout, status.exitstatus, stderr]
    end

    it "loads the Railtie when Rails is already loaded" do
      script = 'require "rails"; require "llm_audit"; print defined?(LlmAudit::Railtie)'
      stdout, exitstatus, stderr = ruby(script)

      expect([stdout, exitstatus]).to eq(["constant", 0]), (stderr unless stderr.empty?)
    end

    it "loads neither Rails nor the Railtie outside Rails" do
      script = 'require "llm_audit"; print [defined?(Rails), defined?(LlmAudit::Railtie)].inspect'
      stdout, exitstatus, stderr = ruby(script)

      expect([stdout, exitstatus]).to eq(["[nil, nil]", 0]), (stderr unless stderr.empty?)
    end
  end
end
