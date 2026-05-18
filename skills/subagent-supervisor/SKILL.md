---
name: subagent-supervisor
description: Dispatch long-running implementation or exploration subtasks to external Claude Code/GLM bash subprocesses, monitor them through a small Elixir daemon, and use a master-thread heartbeat after submitting the intended batch of subagents.
---

# Subagent Supervisor

Use this skill when a task can be split into subprocess-backed subtasks and the master agent thread should keep ownership of decomposition, judgment, integration, and final reporting.

## Assumptions

- The `subagent-supervisor` CLI is available on `PATH` (installed via `scripts/package`).
- The daemon auto-starts on first use — no manual `server` command needed.
- The single daemon is shared by all active sessions on the same host. Create and reuse a distinct session id to isolate waits and filtered lists; use `subagent-supervisor top` to see all supervised jobs across repositories.
- Inspect daemon logs with `subagent-supervisor server logs --lines 80`.
- Pass the prompt text after `--`. The supervisor automatically wraps it in `scripts/claude-subagent`.
- Override daemon concurrency with `subagent-supervisor server --max-concurrency N` if needed. Set server logging with `--log-level debug|info|warning|error|none` or `SUBAGENT_SUPERVISOR_LOG_LEVEL`; rejected launches are logged at INFO. Extra jobs queue until a running job finishes.
- Create a session id once per master agent thread:

```bash
subagent-supervisor session --prefix "$THREAD_ID"
```

Use the returned `session` value for subsequent `--session` calls.

## Dispatch

Start each subtask with a narrow, self-contained prompt and a label:

```bash
subagent-supervisor start --session "$SUBAGENT_SUPERVISOR_SESSION" --agent Plan --label "api-plan" --cwd "$PWD" -- "Read-only planning task. Inspect the API slice and return concise findings with file references."
```

If `--agent` is omitted for a new start, the CLI defaults to the built-in `Plan` agent. This default is intentionally non-destructive. Use an explicit implementation agent for code edits; do not rely on the default for coding work. The command prints JSON containing `id`, `status`, `owner`, `label`, and timestamps. Preserve returned ids when the wake rule applies only to a subset of jobs.

### Agent Dispatch

To dispatch to a specific Claude Code agent, use `--agent NAME`. Available agents are discovered from built-ins, `~/.claude/agents/` (user-level), and `<cwd>/.claude/agents/` (project-level). Always list agents for the target cwd before dispatching implementation work:

```bash
subagent-supervisor agents --cwd "$PWD"
```

Use `Plan` or `Explore` for read-only research/planning. Use `sweng-coder` only for bounded implementation work where the target cwd is inside the effective sandbox write roots. Then dispatch with an explicit agent:

```bash
subagent-supervisor start --session "$SUBAGENT_SUPERVISOR_SESSION" --agent sweng-coder --label "api-slice" --cwd "$PWD" -- "Implement the API slice. Return changed files and test output."
```

The agent name is validated at both the CLI and daemon level — an unknown agent name will produce a clear error listing available agents.

## Default Sandbox Profile

Prefer a sandbox profile that allows repository edits and the agent's dynamic temp directory while keeping git internals and agent configuration protected. Do not permit unsandboxed Bash commands or the `dangerouslyDisableSandbox` escape hatch for supervised subagents.

When running under a parent Codex sandbox, the CLI sends sandbox write roots to the daemon. The daemon also records whether the server process inherited a Codex sandbox and any known server write roots. A job whose `--cwd` is outside the effective roots may still be used for read-only exploration, but write-capable agents such as `sweng-coder` are rejected and the launcher must not include that `cwd` in Claude's `allowWrite` list. Override the default detected roots only with `SUBAGENT_SUPERVISOR_SANDBOX_WRITE_ROOTS` or `SUBAGENT_SUPERVISOR_SERVER_SANDBOX_WRITE_ROOTS` when the parent runtime has explicitly granted those paths.

If an inherited parent sandbox causes nested Bash sandbox initialization to fail, keep the failure closed: report Bash/Python as unavailable for that job rather than disabling or weakening the sandbox.

Do not hardcode observed temp paths; resolve the effective temp root from `$TMPDIR`, `System.tmp_dir!()`, or `mktemp -d` for the current job.

```yaml
sandbox:
  inheritedParent: "$SUBAGENT_SUPERVISOR_INHERITED_SANDBOX"
  enabled: true
  failIfUnavailable: true
  allowUnsandboxedCommands: false
write:
  allowOnly:
    - "."
    - "$TMPDIR"
  denyWithinAllow:
    - "*/.claude/settings*.json"
    - "*/.claude/skills"
    - "*/HEAD"
    - "*/objects"
    - "*/refs"
    - "*/hooks"
```

Claude's effective config dir must have a writable `session-env/` directory; when launching subagents, prefer setting `CLAUDE_CONFIG_DIR` under `$TMPDIR` instead of requiring broad writes to `$HOME/.claude`.

## Start Handoff

`start` returns only after launcher validation succeeds and the daemon has registered an observable job. Treat `accepted: true` and `observable: true` in the returned JSON as the positive handoff confirmation that the job id can be listed, shown, tailed, or waited on.

The returned `status` can be `queued` when the daemon owns the job but all concurrency slots are occupied, or `running` when the subprocess has already been started. Do not block merely to turn `queued` into `running`; use the returned job id/session for follow-up.

For Codex parent agents, the best general workflow is to submit the full batch of wanted subagents first, then have the master thread decide and set a thread heartbeat or equivalent runtime wake mechanism. Choose the heartbeat delay from the expected job size: roughly 10 minutes can be appropriate for long codebase exploration, while roughly 5 minutes is often enough for a medium-sized implementation or investigation. The heartbeat prompt should include the session id and job ids, then inspect `list`, `status`, `show --full`, or `wait` when it resumes.

## Wait Rules

Use `wait` when the parent agent is staying active in the current turn and can consume the result immediately. `wait` is a daemon-side readiness primitive, not by itself a reliable wake mechanism after the parent runtime has yielded or finalized.

```bash
subagent-supervisor wait --session "$SUBAGENT_SUPERVISOR_SESSION" --mode any --timeout 3600
subagent-supervisor wait --session "$SUBAGENT_SUPERVISOR_SESSION" --mode all --timeout 7200
subagent-supervisor wait --session "$SUBAGENT_SUPERVISOR_SESSION" --ids job_a,job_b --mode all --timeout 7200
```

Choose `--mode any` with a long timeout when the active parent can resume from the first returned result, such as reviewing an exploratory finding or starting integration on an independent slice.

Choose `--mode all` with a long timeout when the active parent depends on comparing, merging, or summarizing the whole batch.

Use `--ids` whenever only a subset of dispatched jobs should wake the parent. On timeout, inspect with `list`, `status`, or `tail`, then issue another `wait` rather than switching to manual sleeps.

## Inspect

List active and completed jobs:

```bash
subagent-supervisor list --session "$SUBAGENT_SUPERVISOR_SESSION"
```

Fetch one job, including captured output:

```bash
subagent-supervisor show job_a --full
```

Get a lightweight status digest (metadata + truncated output) without the full raw output:

```bash
subagent-supervisor status job_a
```

Inspect streamed output with the parsed default tail. Use `--verbose` only when debugging raw stream-json events, parser behavior, or missing output:

```bash
subagent-supervisor tail job_a
```

Open the global dashboard:

```bash
subagent-supervisor top
```

## Workflow

1. Keep decomposition in the master agent. Create bounded prompts with explicit expected output.
2. Submit the complete intended batch of subagents up front, subject to the concurrency budget; extra accepted jobs can queue under daemon control.
3. After each `start`, preserve the accepted job id and session.
4. If the parent should yield, set a master-thread heartbeat after dispatching the batch. Pick the delay from the task size, such as about 10 minutes for long codebase exploration or about 5 minutes for a medium-sized job.
5. Wait with `any` or `all` only when the parent remains active and the next useful decision point is inside the current turn.
6. Treat subprocess output as evidence, not authority. Review changed files and commands before integrating.
7. Report final status from the master agent after verification.
