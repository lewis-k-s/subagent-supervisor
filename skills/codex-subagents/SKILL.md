---
name: codex-subagents
description: Dispatch long-running implementation or exploration subtasks to external Claude Code/GLM bash subprocesses, monitor them through a small Elixir daemon, and wait for any or all results before continuing the Codex thread.
---

# Codex Subagents

Use this skill when a task can be split into subprocess-backed subtasks and the main Codex thread should keep ownership of decomposition, judgment, integration, and final reporting.

## Assumptions

- The `codex-subagents` CLI is available on `PATH`.
- A daemon is running for the workspace:

```bash
epmd -daemon
codex-subagents server
```

- Pass the subprocess command and its arguments after `--`. For shell operators such as `;`, pipes, or redirects, use `bash -lc "..."` after `--`.
- Start the daemon with `--max-concurrency N` to match the Claude Code/GLM concurrency budget. Extra jobs queue until a running job finishes.
- Use the current Codex thread id, task id, or another stable string as `--owner`.

## Dispatch

Start each subtask with a narrow, self-contained prompt and a label:

```bash
codex-subagents start --owner "$CODEX_THREAD_ID" --label "api-slice" --cwd "$PWD" -- claude-code --model glm "Implement the API slice. Return changed files and test output."
```

The command prints JSON containing `id`, `status`, `owner`, `label`, and timestamps. Preserve returned ids when the wake rule applies only to a subset of jobs.

## Wake Rules

Use `wait` to block until the daemon can return completed results:

```bash
codex-subagents wait --owner "$CODEX_THREAD_ID" --mode any --timeout 3600
codex-subagents wait --owner "$CODEX_THREAD_ID" --mode all --timeout 7200
codex-subagents wait --owner "$CODEX_THREAD_ID" --ids job_a,job_b --mode all --timeout 7200
```

Choose `--mode any` when Codex can make progress from the first returned result, such as reviewing an exploratory finding or starting integration on an independent slice.

Choose `--mode all` when the next step depends on comparing, merging, or summarizing the whole batch.

## Inspect

List active and completed jobs:

```bash
codex-subagents list --owner "$CODEX_THREAD_ID"
```

Fetch one job, including captured output:

```bash
codex-subagents show job_a
```

## Codex Workflow

1. Keep decomposition in Codex. Create bounded prompts with explicit expected output.
2. Start only as many subprocesses as the concurrency budget allows.
3. Wait with `any` or `all` based on the next useful Codex decision point.
4. Treat subprocess output as evidence, not authority. Review changed files and commands before integrating.
5. Report final status from Codex after verification.
