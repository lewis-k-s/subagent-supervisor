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

Prefer a sandbox profile that allows repository edits, the agent's dynamic temp directory, and Claude shell session setup, while keeping git internals and agent configuration protected.

When a subagent inherits a parent sandbox such as Codex's macOS seatbelt sandbox, Bash tool calls may need `dangerouslyDisableSandbox: true` to avoid nested `sandbox-exec` failure. Only use that workaround when `SUBAGENT_SUPERVISOR_INHERITED_SANDBOX=1`; otherwise let Claude Code apply its own sandbox normally.

Do not hardcode observed temp paths; resolve the effective temp root from `$TMPDIR`, `System.tmp_dir!()`, or `mktemp -d` for the current job.

```yaml
sandbox:
  inheritedParent: "$SUBAGENT_SUPERVISOR_INHERITED_SANDBOX"
  useClaudeCodeSandboxWhenNoParent: true
  disableNestedBashSandboxOnlyWhenInherited: true
write:
  allowOnly:
    - "."
    - "$TMPDIR"
    - "$HOME/.claude/session-env/"
    - "$HOME/.claude/debug"
  denyWithinAllow:
    - "*/.claude/settings*.json"
    - "*/.claude/skills"
    - "*/HEAD"
    - "*/objects"
    - "*/refs"
    - "*/hooks"
```

Claude's effective config dir must have a writable `session-env/` directory; when launching subagents, prefer setting `CLAUDE_CONFIG_DIR` under `$TMPDIR` instead of requiring broad writes to `$HOME/.claude`.

## Wake Rules

Use `wait` to block until the daemon can return completed results:

```bash
subagent-supervisor wait --session "$SUBAGENT_SUPERVISOR_SESSION" --mode any --timeout 3600
subagent-supervisor wait --session "$SUBAGENT_SUPERVISOR_SESSION" --mode all --timeout 7200
subagent-supervisor wait --session "$SUBAGENT_SUPERVISOR_SESSION" --ids job_a,job_b --mode all --timeout 7200
```

Choose `--mode any` when the master agent can make progress from the first returned result, such as reviewing an exploratory finding or starting integration on an independent slice.

Choose `--mode all` when the next step depends on comparing, merging, or summarizing the whole batch.

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
3. Wait with `any` or `all` based on the next useful decision point.
4. Treat subprocess output as evidence, not authority. Review changed files and commands before integrating.
5. Report final status from the master agent after verification.
