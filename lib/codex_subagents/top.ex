defmodule CodexSubagents.Top do
  @moduledoc """
  Terminal UI dashboard for visualizing subagent jobs and supervision tree.

  Implements the Ratatouille.App behaviour (Elm Architecture) and renders
  a live dashboard that polls the daemon via RPC every second.
  """

  @behaviour Ratatouille.App

  import Ratatouille.View

  alias Ratatouille.Runtime.Subscription

  @enforce_keys [:daemon]
  defstruct [
    :daemon,
    :started_at,
    jobs_by_owner: [],
    total_jobs: 0,
    running: 0,
    queued: 0,
    max_concurrency: 2,
    supervision_tree: [],
    scroll_offset: 0,
    error: nil
  ]

  @type t :: %__MODULE__{}

  @impl true
  def init(%{daemon: daemon}) do
    model = %__MODULE__{daemon: daemon}
    fetch_state(model)
  end

  def init(%{window: _window}) do
    daemon = Application.fetch_env!(:codex_subagents, :top_daemon)
    model = %__MODULE__{daemon: daemon}
    fetch_state(model)
  end

  @impl true
  def subscribe(_model) do
    Subscription.interval(1_000, :tick)
  end

  @impl true
  def update(model, msg) do
    case msg do
      :tick ->
        fetch_state(model)

      {:event, %{ch: ?q}} ->
        System.halt(0)

      {:event, %{key: :arrow_up}} ->
        %{model | scroll_offset: max(model.scroll_offset - 1, 0)}

      {:event, %{key: :arrow_down}} ->
        %{model | scroll_offset: model.scroll_offset + 1}

      _ ->
        model
    end
  end

  @impl true
  def render(model) do
    view(top_bar: top_bar(model), bottom_bar: bottom_bar()) do
      row do
        column size: 12 do
          panel title: "Supervision Tree", height: sup_panel_height(model) do
            render_supervision_tree(model.supervision_tree)
          end
        end
      end

      row do
        column size: 12 do
          panel title: jobs_panel_title(model) do
            if model.error do
              label(content: model.error, color: :red)
            else
              if model.total_jobs == 0 do
                label(content: "  No jobs", color: :black)
              else
                render_jobs(model)
              end
            end
          end
        end
      end
    end
  end

  defp fetch_state(%__MODULE__{} = model) do
    case :rpc.call(model.daemon, CodexSubagents.Registry, :dashboard_state, []) do
      {:ok, data} ->
        %__MODULE__{
          model
          | started_at: data.started_at,
            jobs_by_owner: data.jobs_by_owner,
            total_jobs: data.total_jobs,
            running: data.running,
            queued: data.queued,
            max_concurrency: data.max_concurrency,
            supervision_tree: data.supervision_tree,
            error: nil
        }

      {:badrpc, reason} ->
        %{model | error: "daemon unreachable: #{inspect(reason)}"}
    end
  end

  defp top_bar(model) do
    bar do
      label(
        content:
          " codex-subagents | up #{format_uptime(model.started_at)} | running #{model.running}/#{model.max_concurrency} | queued #{model.queued}"
      )
    end
  end

  defp bottom_bar do
    bar do
      label(content: " q quit | arrows scroll")
    end
  end

  defp sup_panel_height(model) do
    tree_size = count_tree_nodes(model.supervision_tree)
    min(max(tree_size + 4, 6), 12)
  end

  defp jobs_panel_title(model) do
    "Jobs (#{model.total_jobs} total)"
  end

  defp render_supervision_tree(tree) do
    tree
    |> Enum.flat_map(&tree_lines/1)
    |> Enum.map(&label(content: &1))
  end

  defp tree_lines(node, depth \\ 0) do
    indent = String.duplicate("  ", depth)
    line = "#{indent}#{node.name} #{format_pid_short(Map.get(node, :pid, "not started"))}"

    [line | Enum.flat_map(Map.get(node, :children, []), &tree_lines(&1, depth + 1))]
  end

  defp render_jobs(model) do
    model.jobs_by_owner
    |> Enum.with_index()
    |> Enum.flat_map(fn {owner_group, idx} ->
      owner_header(owner_group.owner, length(owner_group.jobs), idx == 0) ++
        owner_job_rows(owner_group.jobs)
    end)
  end

  defp owner_header(owner, count, first?) do
    spacer =
      if first?,
        do: [],
        else: [label(content: "")]

    spacer ++
      [label(content: "Owner: #{owner} (#{count} jobs)")]
  end

  defp owner_job_rows(jobs) do
    Enum.map(jobs, fn job ->
      label(content: job_line(job), color: status_color(job.status))
    end)
  end

  defp job_line(job) do
    [
      "  ",
      status_icon(job.status),
      " ",
      pad(truncate_id(job.id), 12),
      pad(to_string(job.status), 11),
      pad(format_duration(job), 8),
      pad(job.label || "", 14),
      truncate_command(job.command)
    ]
    |> IO.iodata_to_binary()
  end

  defp pad(value, width) do
    value = to_string(value)
    value <> String.duplicate(" ", max(width - String.length(value), 1))
  end

  @doc false
  def status_icon(:running), do: "\u25CF"
  def status_icon(:queued), do: "\u25CB"
  def status_icon(:succeeded), do: "\u2713"
  def status_icon(:failed), do: "\u2717"

  @doc false
  def status_color(:running), do: :yellow
  def status_color(:queued), do: :white
  def status_color(:succeeded), do: :green
  def status_color(:failed), do: :red
  def status_color(_), do: :white

  @doc false
  def format_duration(%{status: :queued}), do: ""

  def format_duration(%{status: status, started_at: started_at, finished_at: finished_at})
      when status in [:running, :succeeded, :failed] and not is_nil(started_at) do
    end_time = finished_at || DateTime.utc_now()
    diff = DateTime.diff(end_time, started_at, :second)

    cond do
      diff < 60 -> "#{diff}s"
      diff < 3600 -> "#{div(diff, 60)}m#{rem(diff, 60)}s"
      true -> "#{div(diff, 3600)}h#{rem(diff, 3600) |> div(60)}m"
    end
  end

  def format_duration(_), do: ""

  @doc false
  def format_uptime(nil), do: "unknown"

  def format_uptime(started_at) do
    diff = DateTime.diff(DateTime.utc_now(), started_at, :second)

    cond do
      diff < 60 -> "#{diff}s"
      diff < 3600 -> "#{div(diff, 60)}m#{rem(diff, 60)}s"
      true -> "#{div(diff, 3600)}h#{rem(diff, 3600) |> div(60)}m"
    end
  end

  @doc false
  def truncate_id("job_" <> rest), do: "job_" <> String.slice(rest, 0, 5) <> ".."
  def truncate_id(id), do: String.slice(id, 0, 10)

  @doc false
  def truncate_command(cmd) when byte_size(cmd) > 40, do: String.slice(cmd, 0, 37) <> "..."
  def truncate_command(cmd), do: cmd

  @doc false
  def format_pid_short("not started"), do: "(not started)"
  def format_pid_short(pid_str), do: "(#{pid_str})"

  defp count_tree_nodes(tree) do
    Enum.reduce(tree, 0, fn node, acc ->
      acc + 1 + count_tree_nodes(Map.get(node, :children, []))
    end)
  end
end
