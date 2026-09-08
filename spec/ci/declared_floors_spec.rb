# frozen_string_literal: true

require "yaml"
require "bundler"

# A spec file that reads CI configuration, because the gemspec's two floors - a Ruby and a railties - are
# claims about machines this suite never runs on, and until this file existed nothing checked that the rest
# of the repo agreed with them. Every example here was made red before it was kept, so none of them is a
# claim of the kind they exist to catch.
RSpec.describe "the declared floors" do
  let(:root) { File.expand_path("../..", __dir__) }
  let(:gemspec) { Gem::Specification.load(File.join(root, "llm_audit.gemspec")) }
  let(:ruby_floor) { Gem::Version.new(gemspec.required_ruby_version.requirements.first.last) }
  let(:railties_floor) do
    railties = gemspec.dependencies.find { |dependency| dependency.name == "railties" }

    railties.requirement.requirements.find { |operator, _| operator == ">=" }.last
  end

  # YAML 1.1 reads the `on:` key as the boolean true, so this file reaches the matrix through "jobs" and
  # never through "on".
  let(:workflow) { YAML.safe_load_file(File.join(root, ".github/workflows/main.yml")) }
  let(:legs) { workflow.dig("jobs", "build", "strategy", "matrix", "include") }
  let(:spec_directory) { File.join(root, "spec") }
  let(:spec_files) { Dir.glob("**/*_spec.rb", base: spec_directory).sort }
  let(:spec_directory_files) { Dir.glob("**/*.rb", base: spec_directory).sort }
  let(:client_absent_spec) { "llm_audit/adapters/client_absent_spec.rb" }

  # The client gems are named out of the gem's own manifest and never written down again here: a second
  # adapter has to be subtracted from the client-free bundle, and has to load its client through its own
  # support file, on the day it is declared rather than the day someone remembers these two examples. The
  # quotes are part of the pattern, so a gem merely PREFIXED with a client's name - ruby_llm_extras - is
  # never mistaken for the client itself.
  let(:client_gems) { LlmAudit.adapters.map(&:gem_name) }
  let(:quoted_client_gem) { /["']#{Regexp.union(client_gems)}["']/ }
  let(:client_gem_require) { /^require\s+#{quoted_client_gem}/ }
  let(:client_support_files) { client_gems.map { |gem_name| "support/#{gem_name}_client.rb" }.sort }

  # spec/support/<client>_client.rb is where a client gem gets required at file-load time, and a spec file
  # reaches it with a top-level require_relative. The `_client` suffix is the discriminator: a bare
  # `require "ruby_llm"` does not match it, which is what already excludes the copy of one inside
  # spec/llm_audit_spec.rb's subprocess script string. The column-0 anchor does a different job - it keeps
  # this to file-load-time requires, since an indented one sits inside a block or a quoted script and loads
  # nothing into THIS process, which is the only process a LoadError could fire in. The convention, not the
  # gem name, is what a second adapter will reuse.
  let(:client_require) { /^require(?:_relative)?\s+["'][^"']*_client["']/ }
  let(:client_loading_specs) do
    spec_files.select { |path| File.read(File.join(spec_directory, path)).match?(client_require) }
  end
  let(:excluded_specs) do
    legs.filter_map { |leg| leg["spec_opts"] }
        .flat_map { |opts| opts.scan(/--exclude-pattern\s+(\S+)/).flatten }
        .flat_map { |pattern| Dir.glob(pattern, base: spec_directory) }.uniq.sort
  end

  # Installing writes a lockfile, and `bundler-cache: true` installs, so every matrix leg HAS a lockfile
  # next to its gemfile by the time the suite runs - existence identifies nothing. Only the root
  # Gemfile.lock is committed, and it is the only one a leg can install frozen against; the gemfiles/ legs
  # resolve fresh on their own Ruby and have nothing to be stale about.
  let(:root_bundle) { File.identical?(Bundler.default_gemfile, File.join(root, "Gemfile")) }
  let(:lockfile) { File.read(File.join(root, "Gemfile.lock")) }

  # Read out of the index rather than the working tree on purpose: a non-frozen `bundle exec` re-resolves
  # the path gem and rewrites the working copy back into agreement BEFORE RSpec loads, so a working-tree
  # read would heal the drift it is meant to report and never fire in the local `rake` flow. git is already
  # a hard dependency of this file, through the `git ls-files` inside the gemspec's spec.files.
  let(:staged_lockfile) { IO.popen(%w[git show :Gemfile.lock], chdir: root, err: IO::NULL, &:read) }

  it "reads the gemspec back, so a broken load cannot pass this file vacuously" do
    expect([gemspec.name, ruby_floor, railties_floor])
      .to eq(["llm_audit", Gem::Version.new("3.2.0"), Gem::Version.new("7.1")])
  end

  it "runs a matrix leg on the Ruby the gemspec declares as its floor" do
    expect(legs.map { |leg| leg["ruby"] }).to include(ruby_floor.segments.first(2).join("."))
  end

  # The symmetric half for the other floor, and the direction CI cannot cover on its own: RAISING the
  # gemspec to >= 7.2 makes the `~> 7.1.0` pin unresolvable and both 7.1 legs go red at setup, but LOWERING
  # it to >= 7.0 leaves them green while the newly declared floor is never installed anywhere.
  it "pins the railties floor leg to the version the gemspec declares as its floor, not merely some 7.x" do
    pin = File.read(File.join(root, "gemfiles/rails_7_1.gemfile"))[/^gem "railties", "~> ([\d.]+)"$/, 1]

    expect(pin).not_to be_nil
    expect(Gem::Version.new(pin).segments.first(2)).to eq(railties_floor.segments.first(2))
  end

  # A typo in a leg's gemfile: resolves BUNDLE_GEMFILE to a path that does not exist, and the runner dies in
  # Bundler::GemfileNotFound naming the missing path; a leg missing the key renders it as a bare directory.
  # File.file? rather than File.exist? for exactly that second case.
  it "names a gemfile that exists on every leg, since the matrix is never run locally as a whole" do
    missing = legs.reject { |leg| File.file?(File.join(root, leg["gemfile"].to_s)) }

    expect(missing.map { |leg| [leg["name"], leg["gemfile"]] }).to be_empty
  end

  # The trap this whole session exists to keep fixed. `bundle update` on a 3.4 laptop can pull in a
  # transitive gem that requires >= 3.3 - rbs and parallel both did, via irb->rdoc->rbs and
  # rubocop->parallel - and ruby/setup-ruby turns deployment (frozen) mode on whenever a lockfile exists,
  # so the floor legs then exit 5 at the setup step, naming a gem nothing in this repo declares, before one
  # spec runs. Here it is a red example on the machine that ran the update.
  it "resolves the lockfile to gems every supported Ruby can install, so the floor legs reach the specs" do
    skip "only the root bundle's lockfile is committed" unless root_bundle

    offenders = Bundler.load.specs.reject { |spec| spec.required_ruby_version.satisfied_by?(ruby_floor) }

    expect(offenders.map { |spec| [spec.full_name, spec.required_ruby_version.to_s] }).to be_empty
  end

  # CHECKSUMS is the only supply-chain pin this repo has, and it goes without a word: Ruby 3.2's default
  # bundler 2.4.10 predates the section and drops every entry on any lock rewrite, exit 0, and a stripped
  # lockfile still parses to the same specs, so nothing downstream notices either. Dependabot regenerates
  # the lock with its own bundler too, in a PR whose entire diff is the lockfile. The subtraction is its own
  # canary: a regex that stopped matching would leave every locked gem uncovered rather than none.
  it "keeps a checksum for every gem the lockfile installs, since a rewrite can drop them all silently" do
    skip "only the root bundle's lockfile is committed" unless root_bundle

    checksummed = lockfile.scan(/^ {2}(\S+) \([^)]+\) sha256=/).flatten

    expect(Bundler::LockfileParser.new(lockfile).specs.map(&:name) - checksummed).to eq([gemspec.name])
  end

  # A frozen leg cannot re-resolve a path gem, so a VERSION bump committed without its lockfile breaks the
  # two root-gemfile legs at the setup step with a message about gemspecs having changed.
  it "pins the version the gem declares, since a frozen leg cannot re-resolve a path gem" do
    expect(staged_lockfile).to include("llm_audit (#{LlmAudit::VERSION})")
  end

  it "excludes exactly the spec files that cannot be loaded without a client gem" do
    expect(excluded_specs).to eq(client_loading_specs)
  end

  # client_loading_specs reads *_spec.rb files, so a client required from a SUPPORT file is invisible to it
  # while the client-absent leg dies at load with `0 examples, 1 error` - and spec/support/rails_host.rb,
  # required by two spec files today, is exactly that shape of path. Naming the only file allowed to require
  # a client is what closes that: every other file under spec/ has to reach a client through that file's
  # name, which is where the example above can see it. The column-0 anchor keeps this to file-load-time
  # requires, and is what already excludes the `require "ruby_llm"` inside llm_audit_spec.rb's script string.
  it "requires a client gem in its own support file only: a support file's require is invisible above" do
    requiring = spec_directory_files.select do |path|
      File.read(File.join(spec_directory, path)).match?(client_gem_require)
    end

    expect(requiring).to eq(client_support_files)
  end

  # excluded_specs deliberately forgets which leg each pattern came from, so this is what stops one being
  # pasted onto another: a baseline leg that also skipped those two files would keep every other example
  # here green while quietly running fifty fewer of them.
  it "confines the exclusion to the one leg whose bundle really lacks the client" do
    excluding = legs.select { |leg| leg["spec_opts"] }.map { |leg| leg["gemfile"] }

    expect(excluding).to eq(["gemfiles/no_llm_gems.gemfile"])
  end

  # The first expectation is the canary. The path is a literal, so without it a rename would leave the
  # second one asserting that a file nothing looks for is missing from a list - green forever, guarding
  # nothing, on the one leg that is the only real proof of absence in the matrix.
  it "keeps the client-absent spec inside that leg, since it is the only run that proves real absence" do
    expect(spec_files).to include(client_absent_spec)
    expect(excluded_specs).not_to include(client_absent_spec)
  end

  # Not anchored at column 0: a gem inside a `group ... do` block is indented, and strip makes the two
  # lists comparable regardless - one the guard could not see would be drift it exists to catch.
  it "restates the Gemfile's development gems, minus the client, in the client-free bundle" do
    gem_lines = ->(path) { File.readlines(File.join(root, path)).grep(/^\s*gem\s/).map(&:strip) }

    expect(gem_lines["gemfiles/no_llm_gems.gemfile"]).to eq(gem_lines["Gemfile"].grep_v(quoted_client_gem))
  end

  it "keeps the matrix gemfiles out of the released gem, since spec.files' reject list is case-sensitive" do
    expect(gemspec.files.grep(%r{\Agemfiles/})).to be_empty
    expect(gemspec.files).to include("lib/llm_audit.rb")
  end
end
