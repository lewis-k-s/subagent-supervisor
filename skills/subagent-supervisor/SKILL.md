---
name: subagent-supervisor
description: Dispatch long-running implementation or exploration subtasks to external Claude Code/GLM bash subprocesses, monitor them through a small Elixir daemon, and wait for any or all results before continuing the master agent thread.
---

# Subagent Supervisor

Use this skill when a task can be split into subprocess-backed subtasks and the master agent thread should keep ownership of decomposition, judgment, integration, and final reporting.

## Assumptions

- The `subagent-supervisor` CLI is available on `PATH` (installed via `scripts/package`).
- The daemon auto-starts on first use — no manual `server` command needed.
- The single daemon is shared by all active sessions on the same host. Create and reuse a distinct session id to isolate waits and filtered lists; use `subagent-supervisor top` to see all supervised jobs across repositories.
- Pass the prompt text after `--`. The supervisor automatically wraps it in `scripts/claude-subagent`.
- Override daemon concurrency with `subagent-supervisor server --max-concurrency N` if needed. Extra jobs queue until a running job finishes.
- Create a session id once per master agent thread:

```bash
subagent-supervisor session --prefix "$THREAD_ID"
```

Use the returned `session` value for subsequent `--session` calls.

## Dispatch

Start each subtask with a narrow, self-contained prompt and a label:

```bash
subagent-supervisor start --session "$SUBAGENT_SUPERVISOR_SESSION" --label "api-slice" --cwd "$PWD" -- "Implement the API slice. Return changed files and test output."
```

The command prints JSON containing `id`, `status`, `owner`, `label`, and timestamps. Preserve returned ids when the wake rule applies only to a subset of jobs.

### Agent Dispatch

To dispatch to a specific Claude Code agent, use `--agent NAME`. Available agents are discovered from `~/.claude/agents/` (user-level) and `<cwd>/.claude/agents/` (project-level). List available agents with:

```bash
subagent-supervisor agents
```

Then dispatch with:

```bash
subagent-supervisor start --session "$SUBAGENT_SUPERVISOR_SESSION" --agent docs-czar --label "api-docs" --cwd "$PWD" -- "Document the API endpoints"
```

The agent name is validated at both the CLI and daemon level — an unknown agent name will produce a clear error listing available agents.

## Default Sandbox Profile

Prefer a sandbox profile that allows repository edits and the agent's dynamic temp directory while keeping git internals and agent configuration protected. Do not permit unsandboxed Bash commands or the `dangerouslyDisableSandbox` escape hatch for supervised subagents.

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

For Codex parent agents that need to yield after dispatch, create a thread heartbeat or equivalent runtime wake mechanism after the start handoff is confirmed. The heartbeat prompt should include the session id and job ids, then inspect `list`, `status`, `show --full`, or `wait` when it resumes.

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
2. Start only as many subprocesses as the concurrency budget allows.
3. After each `start`, preserve the accepted job id and session. If the parent must yield, schedule a runtime wake/heartbeat for those ids.
4. Wait with `any` or `all` only when the parent remains active and the next useful decision point is inside the current turn.
5. Treat subprocess output as evidence, not authority. Review changed files and commands before integrating.
6. Report final status from the master agent after verification.
