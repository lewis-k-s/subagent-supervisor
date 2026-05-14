defmodule SubagentSupervisor.Top do
  @moduledoc """
  Terminal UI dashboard for visualizing subagent jobs and supervision tree.

  Implements the Ratatouille.App behaviour (Elm Architecture) and renders
  a live dashboard that polls the daemon via RPC every 250ms. Supports
  interactive job selection and full-screen output viewing with incremental
  parsing and visible-only rendering for fast updates.
  """

  @behaviour Ratatouille.App

  @enforce_keys [:daemon]
  defstruct [
    :daemon,
    :started_at,
    :window_height,
    :window_width,
    jobs_by_owner: [],
    all_jobs: [],
    total_jobs: 0,
    running: 0,
    queued: 0,
    max_concurrency: 2,
    supervision_tree: [],
    scroll_offset: 0,
    selected_index: 0,
    view_mode: :dashboard,
    selected_job_id: nil,
    selected_job_output: [],
    output_verbose: false,
    output_scroll: 0,
    output_auto_scroll: true,
    output_byte_offset: 0,
    error: nil
  ]

  @type t :: %__MODULE__{}

  @impl true
  defdelegate init(ctx), to: SubagentSupervisor.Top.Model

  @impl true
  defdelegate subscribe(model), to: SubagentSupervisor.Top.Model

  @impl true
  defdelegate update(model, msg), to: SubagentSupervisor.Top.Model

  @impl true
  defdelegate render(model), to: SubagentSupervisor.Top.View

  defdelegate status_icon(status), to: SubagentSupervisor.Top.Format
  defdelegate status_color(status), to: SubagentSupervisor.Top.Format
  defdelegate format_duration(job), to: SubagentSupervisor.Top.Format
  defdelegate format_uptime(started_at), to: SubagentSupervisor.Top.Format
  defdelegate truncate_id(id), to: SubagentSupervisor.Top.Format
  defdelegate truncate_command(cmd), to: SubagentSupervisor.Top.Format
  defdelegate format_pid_short(pid_str), to: SubagentSupervisor.Top.Format
end
