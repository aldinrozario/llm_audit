# llm_audit

Audit a Rails app that calls LLMs for the security and reliability risks unique to that: unbounded
consumption (missing timeouts, retries, token and cost caps), leaked provider keys, unauthorized AI
tool surfaces, and model output reaching trusted sinks. Findings are mapped to the
[OWASP Top 10 for LLM Applications](https://genai.owasp.org/llm-top-10/).

One gem, two entry points over the same engine:

- **`rails llm_audit:doctor`** — inspects the *running* app: boots it, reads each LLM client's live
  configuration, runs the checks, prints findings. Available now.
- **RuboCop `LLM/` cops** — the same checks against the code, for call sites the running app cannot
  show. Planned (see [Roadmap](#roadmap)).

## Status

Pre-release (`0.1.0` unreleased). The `doctor` engine is complete for the unbounded-consumption
family against two clients; it has not yet been validated against real production apps, which is the
next milestone. Expect the check set and output to change before the first RubyGems release.

## Installation

Not on RubyGems yet. Add it from git:

```ruby
# Gemfile
gem "llm_audit", github: "aldinrozario/llm_audit"
```

Keep it outside the `development` / `test` groups: the audit is most useful run under the
production configuration, and a gem in a group Bundler does not require there has no rake task
there. It adds no runtime behaviour to the app — only the `llm_audit:doctor` task.

Requires Ruby >= 3.2 and Rails 7.1 through 8.x.

## Usage

```bash
bin/rails llm_audit:doctor
```

The audit reads whatever configuration the app booted with, so run it where the configuration you
care about loads — the banner names the environment it audited and warns when that is `development`:

```
llm_audit: environment: development
llm_audit: warning: the development environment was audited. Client timeouts, retries and caps commonly differ between development and production, so a value read here is no evidence of what production runs on; run this audit where production's configuration loads.

llm_audit: 6 findings

[WARNING] request_timeout: the ruby_llm client runs on the client's own default request timeout of 300s, which this app cannot be shown to have chosen, and that is over the 30s this check allows [300/30]. It bounds one attempt rather than the whole call, which retries multiply, and a request stalled inside it holds the worker that made it.
  location:    (config)
  remediation: Set a timeout at or below 30s: `RubyLLM.configure { |config| config.request_timeout = 30 }`, conventionally in `config/initializers/ruby_llm.rb`. If every call through this client runs in a background job rather than a web request, a longer timeout can be deliberate: this audit reads global configuration and cannot see the call site.
  owasp:       LLM06:2026 Unbounded Consumption

[UNDETERMINED] request_timeout: the ruby-openai client is not loaded in this process, so its request timeout could not be read - undetermined, not a pass.
  location:    (config)
  remediation: Run this audit where the app loads its client: `rails llm_audit:doctor` boots the host app first. If the app does not use ruby-openai at all, there is nothing to fix.
  owasp:       LLM06:2026 Unbounded Consumption
…
```

### What it checks today

| Check | Reads | Flags |
|---|---|---|
| `request_timeout` | the client's effective per-request timeout | over 30s, or unset and inherited from the client's default |
| `max_retries` | the client's effective retry count | over 3, unbounded, or a client that never retries at all |
| `max_output_tokens` | the client-wide output-token cap | over 4096, unset, or a client that has no such cap |

Every check compares the live value against a freshly built default configuration, so "the app never
set this" is detected rather than guessed — no baseline number is hardcoded in the gem.

### Supported clients

| Client | Status |
|---|---|
| [`ruby_llm`](https://github.com/crmne/ruby_llm) | supported |
| [`ruby-openai`](https://github.com/alexrudall/ruby-openai) | supported (retries are read off the Faraday retry middleware the app wired, or reported as none) |
| official `openai` / `anthropic` SDKs | planned |

### Three things it will not do

- **Report OK for something it could not read.** A client that is not loaded, a value the client's
  API no longer exposes, a check that raised — each is reported as `[UNDETERMINED]`, never omitted
  and never counted as a pass.
- **Assume the environment.** The audited `Rails.env` is printed first, and `development` carries an
  explicit warning, because timeouts commonly differ between development and production.
- **Print a provider key.** Client configuration objects carry every API key they were given; no
  code path renders one into a finding or onto stdout, and the test suite lexes the gem's own source
  to keep it that way.

## Roadmap

- **M1** — `doctor` + the unbounded-consumption family (this milestone; validation against real apps
  and a `.llm_audit.yml` for disabling checks and overriding thresholds still to land).
- **M2** — RuboCop `LLM/` cops for the same checks plus hardcoded-key detection; official `openai`
  and `anthropic` adapters.
- **M3** — JSON, SARIF and HTML reports with OWASP scoring.

Progress is tracked in [the issues](https://github.com/aldinrozario/llm_audit/issues).

## Development

```bash
bin/setup              # install dependencies
bundle exec rspec      # run the suite
bundle exec rubocop    # lint
bin/console            # interactive prompt with the gem loaded
```

Specs never call a real LLM provider: they run against placeholder keys and assert the configuration
the gem reads. CI runs the suite across the supported Ruby and Rails floors and once more with no
client gem installed at all.

## Contributing

Bug reports and pull requests are welcome at https://github.com/aldinrozario/llm_audit. Everyone
interacting in this project's codebase and issue tracker is expected to follow the
[code of conduct](https://github.com/aldinrozario/llm_audit/blob/main/CODE_OF_CONDUCT.md).

## License

Released under the [MIT License](https://opensource.org/licenses/MIT).
