# subagent-supervisor

Elixir daemon/CLI for dispatching bash subprocess jobs with concurrency control.

## Build & Run

```bash
mix deps.get                 # fetch deps (includes ratatouille + ex_termbox)
mix escript.build            # compiles ./subagent-supervisor
scripts/package              # builds installable release in ~/.local/subagent-supervisor
./subagent-supervisor server # starts the daemon (blocks)
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

Seven modules in `lib/subagent_supervisor/`:

| Module | Role |
|---|---|
| `Application` | OTP app + supervisor tree (TaskSupervisor, Registry) |
| `Registry` | GenServer — owns all job state, dispatches bash tasks, manages waiters |
| `CLI` | escript entry point; CLI↔daemon via Erlang distribution (`:rpc.call`) |
| `Job` | struct with `@enforce_keys` for immutable job metadata |
| `JSON` | hand-rolled encoder (zero external deps) |
| `Top` | Ratatouille TUI dashboard — live view of jobs & supervision tree |
| `Agents` | Discovers and validates Claude Code agent definitions from filesystem |

Daemon and CLI communicate over distributed Erlang (short names, shared cookie `:subagent_supervisor`). The daemon node name is host-global (`subagent_supervisor@<host>`), so one server is shared across active sessions and repositories on the same host. External dependency: `ratatouille` (TUI framework, used only by the `top` command).

The daemon auto-starts on first use — any CLI command (`start`, `wait`, `list`, `show`, `tail`, `top`) will spawn the daemon in the background if it is not already running.

## Code Conventions

- `@enforce_keys` on all structs
- `@impl true` on every GenServer/Application callback
- `@moduledoc false` on internal modules (Application, CLI, JSON)
- Map-based attrs (`%{"owner" => ...}`) for public API boundaries
- Custom JSON encoder — never add a JSON dependency
- IDs are `job_`-prefixed Base64URL from `:crypto.strong_rand_bytes/1`

## Testing Pattern

- `SubagentSupervisor.Registry.reset_for_test/1` in every `setup` block for clean state
- Pass `@tag max_concurrency: N` to override concurrency per test
- Tests live in `test/` mirroring module names

## CLI Quick Reference

```
subagent-supervisor server [--max-concurrency N]
subagent-supervisor stop
subagent-supervisor session [--prefix PREFIX]
subagent-supervisor agents [--cwd DIR]
subagent-supervisor start --owner ID|--session ID [--label L] [--agent NAME] [--cwd DIR] -- PROMPT
subagent-supervisor wait  --owner ID|--session ID [--ids A,B] [--mode any|all] [--timeout SEC]
subagent-supervisor list  [--owner ID|--session ID]
subagent-supervisor show  JOB_ID [--full]
subagent-supervisor status JOB_ID [--summarize]
subagent-supervisor tail  JOB_ID [--follow|-f]
subagent-supervisor top
```

The `start` command wraps the given PROMPT in `scripts/claude-subagent` automatically.
Only `claude-subagent` is allowed as a launcher — raw bash commands are rejected by the daemon.
In test mode (`config/test.exs`), `allowed_launchers: ["bash"]` permits direct bash for unit tests.

The `--agent NAME` flag passes an agent name through to `claude --agent NAME`. Both the CLI and daemon validate the agent exists in `~/.claude/agents/` (user-level) or `<cwd>/.claude/agents/` (project-level) before dispatching. Use `subagent-supervisor agents` to list available agents.

## Key Paths

- Source: `lib/subagent_supervisor/*.ex`
- Tests: `test/*_test.exs`
- Config: `config/config.exs`, `config/dev.exs`, `config/test.exs`
- Launcher script: `scripts/claude-subagent`
- Skill definition: `skills/subagent-supervisor/SKILL.md`
- Escript config: `mix.exs` (`escript: [main_module: CLI, name: "subagent-supervisor"]`)
- Release package script: `scripts/package`
