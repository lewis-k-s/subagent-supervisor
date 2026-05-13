# codex-subagents

An Elixir CLI/release that runs as a host-global background daemon and lets Codex (or any orchestrator) dispatch bash subprocess jobs with bounded concurrency, `any`/`all` wait semantics, captured output, and a live `top` dashboard.

## Architecture

```
┌─────────────┐   Erlang distribution   ┌──────────────────────────┐
│  CLI (RPC)  │ ◄──────────────────────► │  Daemon GenServer        │
│  escript    │                          │  ├─ bounded job queue    │
│             │                          │  ├─ Task.Supervisor      │
│             │                          │  └─ wait semantics       │
└─────────────┘                          └──────────────────────────┘
```

The daemon is a supervised OTP application. The CLI connects via Erlang distribution (short names) and issues RPC calls. The daemon node name is `codex_subagents@<host>`, so one server is shared by all active Codex sessions on the same host, regardless of their current repository. All communication uses a custom zero-dep JSON encoder.

## Prerequisites

- Elixir >= 1.15 (no external dependencies)
- EPMD running (`epmd -daemon`)

## Build & Install

```bash
mix escript.build
```

This produces a development escript at `./codex-subagents`.

For an installable tool that can be run from any repository and supports the `top` dashboard, build the release package:

```bash
scripts/package
```

This writes a contained package to `dist/codex-subagents` by default. Add `dist/codex-subagents/bin` to `PATH`, or pass a target directory:

```bash
scripts/package ~/.local/codex-subagents
```

The release package includes the native `ex_termbox` NIF on disk, which is required for `codex-subagents top`. Escripts cannot load that NIF from inside the escript archive, so the development escript falls back to `mix run` when it lives beside this source checkout.

## Commands

### Start the daemon

```bash
codex-subagents server --max-concurrency 2
```

Starts the host-global daemon process. `--max-concurrency` sets how many bash jobs run simultaneously across all connected Codex sessions; extra jobs queue in FIFO order. Defaults to `2`, minimum `1`.

### Stop the daemon

```bash
codex-subagents stop
```

### Create a session id

```bash
codex-subagents session --prefix my-thread
```

Returns JSON with a short readable `session` id. Reuse this value with `--session` on `start`, `wait`, and `list` to isolate one master agent's jobs from other active sessions on the same global daemon.

### Dispatch a job

```bash
codex-subagents start --session my-thread-abc123 --label "api-slice" --cwd /tmp -- echo "hello"
```

Required flags:

- `--session` or `--owner` — string identifying the calling thread/task

Optional flags:

- `--label` — human-readable label for the job
- `--cwd` — working directory for the subprocess (defaults to current directory)

The command and its arguments follow `--`. For shell operators, pipes, or redirects, wrap in `bash -lc`:

```bash
codex-subagents start --session my-thread-abc123 --cwd /tmp -- bash -lc "echo hello && echo world"
```

Output is JSON with `id`, `status`, `owner`, `label`, `command`, and timestamps.

### Wait for results

```bash
# Block until ALL jobs for the owner are done
codex-subagents wait --session my-thread-abc123 --mode all --timeout 3600

# Return as soon as ANY one job finishes
codex-subagents wait --session my-thread-abc123 --mode any --timeout 3600

# Wait for specific jobs by id
codex-subagents wait --session my-thread-abc123 --ids job_a,job_b --mode all --timeout 3600
```

- `--mode` — `any` returns when the first matching job finishes; `all` waits for every matching job
- `--timeout` — seconds to wait before returning `{:error, :timeout}` (default: 86400)
- `--ids` — comma-separated job ids to wait on (alternative to owner-based selection)
- `--session`, `--owner`, or `--ids` is required

### List jobs

```bash
# All jobs
codex-subagents list

# Filtered by owner
codex-subagents list --session my-thread-abc123
```

### Show a single job

```bash
codex-subagents show <JOB_ID>
```

Returns full job details including captured output.

### Dashboard

```bash
codex-subagents top
```

Shows all jobs known to the global daemon, grouped by owner, across every repository and active Codex session on the same host.

### Help

```bash
codex-subagents help
codex-subagents --help
```

## Configuration

| Setting | Flag | Default | Description |
|---|---|---|---|
| Max concurrency | `--max-concurrency` | 2 | Simultaneous bash subprocesses |

Set when starting the daemon; cannot be changed at runtime.

## Testing

```bash
mix test
```

Tests use `CodexSubagents.Registry.reset_for_test/1` to isolate state between cases.

## License

MIT
