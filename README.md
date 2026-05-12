# codex-subagents

A zero-dependency Elixir escript that runs as a background daemon and lets Codex (or any orchestrator) dispatch bash subprocess jobs with bounded concurrency, `any`/`all` wait semantics, and captured output.

## Architecture

```
┌─────────────┐   Erlang distribution   ┌──────────────────────────┐
│  CLI (RPC)  │ ◄──────────────────────► │  Daemon GenServer        │
│  escript    │                          │  ├─ bounded job queue    │
│             │                          │  ├─ Task.Supervisor      │
│             │                          │  └─ wait semantics       │
└─────────────┘                          └──────────────────────────┘
```

The daemon is a supervised OTP application. The CLI connects via Erlang distribution (short names) and issues RPC calls. All communication uses a custom zero-dep JSON encoder.

## Prerequisites

- Elixir >= 1.15 (no external dependencies)
- EPMD running (`epmd -daemon`)

## Build & Install

```bash
mix escript.build
```

This produces a self-contained `codex-subagents` executable. Put it on `PATH` or invoke it directly.

## Commands

### Start the daemon

```bash
codex-subagents server --max-concurrency 2
```

Starts the daemon process. `--max-concurrency` sets how many bash jobs run simultaneously; extra jobs queue in FIFO order. Defaults to `2`, minimum `1`.

### Stop the daemon

```bash
codex-subagents stop
```

### Dispatch a job

```bash
codex-subagents start --owner my-thread --label "api-slice" --cwd /tmp -- echo "hello"
```

Required flags:

- `--owner` — string identifying the calling thread/task

Optional flags:

- `--label` — human-readable label for the job
- `--cwd` — working directory for the subprocess (defaults to current directory)

The command and its arguments follow `--`. For shell operators, pipes, or redirects, wrap in `bash -lc`:

```bash
codex-subagents start --owner my-thread --cwd /tmp -- bash -lc "echo hello && echo world"
```

Output is JSON with `id`, `status`, `owner`, `label`, `command`, and timestamps.

### Wait for results

```bash
# Block until ALL jobs for the owner are done
codex-subagents wait --owner my-thread --mode all --timeout 3600

# Return as soon as ANY one job finishes
codex-subagents wait --owner my-thread --mode any --timeout 3600

# Wait for specific jobs by id
codex-subagents wait --owner my-thread --ids job_a,job_b --mode all --timeout 3600
```

- `--mode` — `any` returns when the first matching job finishes; `all` waits for every matching job
- `--timeout` — seconds to wait before returning `{:error, :timeout}` (default: 86400)
- `--ids` — comma-separated job ids to wait on (alternative to owner-based selection)
- `--owner` or `--ids` is required

### List jobs

```bash
# All jobs
codex-subagents list

# Filtered by owner
codex-subagents list --owner my-thread
```

### Show a single job

```bash
codex-subagents show <JOB_ID>
```

Returns full job details including captured output.

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
