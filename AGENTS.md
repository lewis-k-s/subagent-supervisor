# subagent-supervisor

Elixir daemon/CLI for dispatching bash subprocess jobs with concurrency control.

## Build & Run

```bash
mix deps.get                 # fetch deps (includes ratatouille + ex_termbox)
mix escript.build            # compiles ./codex-subagents
scripts/package              # builds installable release in dist/codex-subagents
epmd -daemon                 # required before any command
./codex-subagents server     # starts the daemon (blocks)
```

> **Note:** `ex_termbox` (used by ratatouille) requires Python ≤3.11 at build time
> for its `waf` build system. If `mix deps.compile` fails, run:
> ```bash
> uv python install 3.9
> uv venv .venv39 --python 3.9
> PATH=".venv39/bin:$PATH" mix deps.compile ex_termbox --force
> ```

## Test

```bash
mix test                        # unit tests
mix format --check-formatted    # style check
```

## Architecture

Six modules in `lib/codex_subagents/`:

| Module | Role |
|---|---|
| `Application` | OTP app + supervisor tree (TaskSupervisor, Registry) |
| `Registry` | GenServer — owns all job state, dispatches bash tasks, manages waiters |
| `CLI` | escript entry point; CLI↔daemon via Erlang distribution (`:rpc.call`) |
| `Job` | struct with `@enforce_keys` for immutable job metadata |
| `JSON` | hand-rolled encoder (zero external deps) |
| `Top` | Ratatouille TUI dashboard — live view of jobs & supervision tree |

Daemon and CLI communicate over distributed Erlang (short names, shared cookie `:codex_subagents`). The daemon node name is host-global (`codex_subagents@<host>`), so one server is shared across active Codex sessions and repositories on the same host. External dependency: `ratatouille` (TUI framework, used only by the `top` command).

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
codex-subagents session [--prefix PREFIX]
codex-subagents start --owner ID|--session ID [--label L] [--cwd DIR] -- CMD args...
codex-subagents wait  --owner ID|--session ID [--ids A,B] [--mode any|all] [--timeout SEC]
codex-subagents list  [--owner ID|--session ID]
codex-subagents show  JOB_ID
codex-subagents top
```

## Key Paths

- Source: `lib/codex_subagents/*.ex`
- Tests: `test/*_test.exs`
- Skill definition: `skills/codex-subagents/SKILL.md`
- Escript config: `mix.exs` (`escript: [main_module: CLI, name: "codex-subagents"]`)
- Release package script: `scripts/package`
