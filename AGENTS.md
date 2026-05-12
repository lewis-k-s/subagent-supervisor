# subagent-supervisor

Elixir daemon/CLI for dispatching bash subprocess jobs with concurrency control.

## Build & Run

```bash
mix escript.build        # compiles ./codex-subagents
epmd -daemon              # required before any command
./codex-subagents server  # starts the daemon (blocks)
```

## Test

```bash
mix test                        # unit tests
mix format --check-formatted    # style check
```

## Architecture

Five modules in `lib/codex_subagents/`:

| Module | Role |
|---|---|
| `Application` | OTP app + supervisor tree (TaskSupervisor, Registry) |
| `Registry` | GenServer — owns all job state, dispatches bash tasks, manages waiters |
| `CLI` | escript entry point; CLI↔daemon via Erlang distribution (`:rpc.call`) |
| `Job` | struct with `@enforce_keys` for immutable job metadata |
| `JSON` | hand-rolled encoder (zero external deps) |

Daemon and CLI communicate over distributed Erlang (short names, shared cookie `:codex_subagents`). No external dependencies — only `:logger` and `:crypto` from OTP.

## Code Conventions

- `@enforce_keys` on all structs
- `@impl true` on every GenServer/Application callback
- `@moduledoc false` on internal modules (Application, CLI, JSON)
- Map-based attrs (`%{"owner" => ...}`) for public API boundaries
- Custom JSON encoder — never add a JSON dependency
- IDs are `job_`-prefixed Base64URL from `:crypto.strong_rand_bytes/1`

## Testing Pattern

- `CodexSubagents.Registry.reset_for_test/1` in every `setup` block for clean state
- Pass `@tag max_concurrency: N` to override concurrency per test
- Tests live in `test/` mirroring module names

## CLI Quick Reference

```
codex-subagents server [--max-concurrency N]
codex-subagents stop
codex-subagents start --owner ID [--label L] [--cwd DIR] -- CMD args...
codex-subagents wait  --owner ID [--ids A,B] [--mode any|all] [--timeout SEC]
codex-subagents list  [--owner ID]
codex-subagents show  JOB_ID
```

## Key Paths

- Source: `lib/codex_subagents/*.ex`
- Tests: `test/*_test.exs`
- Skill definition: `skills/codex-subagents/SKILL.md`
- Escript config: `mix.exs` (`escript: [main_module: CLI, name: "codex-subagents"]`)
