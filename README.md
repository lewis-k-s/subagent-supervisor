# subagent-supervisor

An Elixir CLI/release that runs as a host-global background daemon and lets any orchestrator dispatch bash subprocess jobs with bounded concurrency, `any`/`all` wait semantics, captured output, and a live `top` dashboard.

## Architecture

```
┌─────────────┐   Erlang distribution   ┌──────────────────────────┐
│  CLI (RPC)  │ ◄──────────────────────► │  Daemon GenServer        │
│  escript    │                          │  ├─ bounded job queue    │
│             │                          │  ├─ Task.Supervisor      │
│             │                          │  └─ wait semantics       │
└─────────────┘                          └──────────────────────────┘
```

The daemon is a supervised OTP application. The CLI connects via Erlang distribution (short names) and issues RPC calls. The daemon node name is `subagent_supervisor@<host>`, so one server is shared by all active sessions on the same host, regardless of their current repository. All communication uses a custom zero-dep JSON encoder.

The daemon auto-starts on first use — any CLI command will spawn it in the background if it is not already running.

## Prerequisites

- Elixir >= 1.15 (no external dependencies)

## Build & Install

```bash
mix escript.build
```

This produces a development escript at `./subagent-supervisor`.

For an installable tool that can be run from any repository and supports the `top` dashboard, build the release package:

```bash
scripts/package
```

This installs to `~/.local/subagent-supervisor` and symlinks the wrapper to `~/.local/bin`. Ensure `~/.local/bin` is on your PATH.

The package script fetches Mix dependencies, builds the release, installs the
`subagent-supervisor` and `claude-subagent` wrappers, and copies project Claude
agents from `.claude/agents/*.md` to `~/.claude/agents/` so `--agent` names such
as `sweng-coder` are available from any repository.

The release package includes the native `ex_termbox` NIF on disk, which is required for `subagent-supervisor top`. Escripts cannot load that NIF from inside the escript archive, so the development escript falls back to `mix run` when it lives beside this source checkout.

## Commands

### Start the daemon

```bash
subagent-supervisor server --max-concurrency 4
```

Starts the host-global daemon process. `--max-concurrency` sets how many bash jobs run simultaneously across all connected sessions; extra jobs queue in FIFO order. Defaults to `4`, minimum `1`.

The daemon also auto-starts when any other command is run. Manual `server` is only needed to set custom flags or run in the foreground.

### Stop the daemon

```bash
subagent-supervisor stop
```

### Create a session id

```bash
subagent-supervisor session --prefix my-thread
```

Returns JSON with a short readable `session` id. Reuse this value with `--session` on `start`, `wait`, and `list` to isolate one master agent's jobs from other active sessions on the same global daemon.

### Dispatch a job

```bash
subagent-supervisor start --session my-thread-abc123 --label "api-slice" --cwd /tmp -- "Implement the API slice."
```

Required flags:

- `--session` or `--owner` — string identifying the calling thread/task

Optional flags:

- `--label` — human-readable label for the job
- `--cwd` — working directory for the subprocess (defaults to current directory)

The prompt text follows `--`. The supervisor automatically wraps it in `scripts/claude-subagent`. Only `claude-subagent` is allowed as a launcher — raw bash commands are rejected.

`start` returns only after launcher validation has passed and the daemon has durably registered the job. The returned `id` is immediately observable with `list`, `show`, `status`, `tail`, and `wait`. The returned `status` may be `running` when a concurrency slot was available, or `queued` when the daemon owns the job but it is waiting behind other work.

Output is JSON with `id`, `accepted`, `observable`, `status`, `owner`, `label`, `command`, and timestamps. Callers that need to yield after dispatch should treat `accepted: true` and `observable: true` as the positive handoff confirmation, then schedule their runtime's wake/follow-up mechanism against the returned session or job ids.

### Wait for results

`wait` is the daemon-side readiness primitive for an active caller. Use it when the parent process is going to remain alive and consume the result in the same turn.

Do not rely on a long-running `wait` call as the only wake mechanism for runtimes that may yield or finalize the parent turn while subprocesses continue. For Codex-style callers, dispatch jobs, confirm `accepted: true`, schedule a thread heartbeat or equivalent wake mechanism for the returned session/job ids, and let that follow-up inspect completed jobs.

```bash
# Block until ALL jobs for the owner are done
subagent-supervisor wait --session my-thread-abc123 --mode all --timeout 3600

# Return as soon as ANY one job finishes
subagent-supervisor wait --session my-thread-abc123 --mode any --timeout 3600

# Wait for specific jobs by id
subagent-supervisor wait --session my-thread-abc123 --ids job_a,job_b --mode all --timeout 3600
```

- `--mode` — `any` returns when the first matching job finishes; `all` waits for every matching job
- `--timeout` — seconds to wait before returning `{:error, :timeout}` (default: 86400)
- `--ids` — comma-separated job ids to wait on (alternative to owner-based selection)
- `--session`, `--owner`, or `--ids` is required

Use `--mode any` when the active parent can act on the first completed subagent, `--mode all` when it needs the full batch, and `--ids` when only specific jobs should return from that blocking wait. If a wait times out, inspect job state and wait again rather than replacing the daemon wait with ad hoc sleeps.

### List jobs

```bash
# All jobs
subagent-supervisor list

# Filtered by owner
subagent-supervisor list --session my-thread-abc123
```

### Show a single job

```bash
subagent-supervisor show <JOB_ID>
```

Returns full job details including captured output.

### Dashboard

```bash
subagent-supervisor top
```

Shows all jobs known to the global daemon, grouped by owner, across every repository and active session on the same host.

### Help

```bash
subagent-supervisor help
subagent-supervisor --help
```

## Configuration

| Setting | Flag | Default | Description |
|---|---|---|---|
| Max concurrency | `--max-concurrency` | 4 | Simultaneous bash subprocesses |

Set when starting the daemon; cannot be changed at runtime.

## Testing

```bash
mix test
```

Tests use `SubagentSupervisor.Registry.reset_for_test/1` to isolate state between cases.

## License

MIT
