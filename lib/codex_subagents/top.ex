defmodule CodexSubagents.Top do
  @moduledoc """
  Terminal UI dashboard for visualizing subagent jobs and supervision tree.

  Implements the Ratatouille.App behaviour (Elm Architecture) and renders
  a live dashboard that polls the daemon via RPC every second. Supports
  interactive job selection and full-screen output viewing.
  """

  @behaviour Ratatouille.App

  import Ratatouille.Constants, only: [key: 1, event_type: 1]

  @key_esc key(:esc)
  @key_enter key(:enter)
  @key_arrow_up key(:arrow_up)
  @key_arrow_down key(:arrow_down)
  @event_resize event_type(:resize)

  import Ratatouille.View

  alias Ratatouille.Runtime.Subscription

  @enforce_keys [:daemon]
  defstruct [
    :daemon,
    :started_at,
    :window_height,
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
    selected_job_output: "",
    output_scroll: 0,
    output_auto_scroll: true,
    error: nil
  ]

  @type t :: %__MODULE__{}

  @impl true
  def init(%{daemon: daemon, window: %{height: height}}) do
    model = %__MODULE__{daemon: daemon, window_height: height}
    fetch_state(model)
  end

  def init(%{daemon: daemon}) do
    model = %__MODULE__{daemon: daemon}
    fetch_state(model)
  end

  def init(%{window: %{height: height}}) do
    daemon = Application.fetch_env!(:codex_subagents, :top_daemon)
    model = %__MODULE__{daemon: daemon, window_height: height}
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
        model = fetch_state(model)

        if model.view_mode == :output and model.selected_job_id do
          fetch_output(model)
        else
          model
        end

      {:event, %{ch: ?q}} ->
        if model.view_mode == :dashboard do
          System.halt(0)
        else
          model
        end

      {:event, %{key: @key_esc}} ->
        if model.view_mode == :output do
          %{
            model
            | view_mode: :dashboard,
              selected_job_id: nil,
              selected_job_output: "",
              output_scroll: 0
          }
        else
          model
        end

      {:event, %{key: @key_enter}} ->
        if model.view_mode == :dashboard and model.total_jobs > 0 do
          job = Enum.at(model.all_jobs, model.selected_index)

          if job do
            model = %{
              model
              | view_mode: :output,
                selected_job_id: job.id,
                output_scroll: 0,
                output_auto_scroll: true
            }

            fetch_output(model)
          else
            model
          end
        else
          model
        end

      {:event, %{key: @key_arrow_up}} ->
        handle_arrow_up(model)

      {:event, %{key: @key_arrow_down}} ->
        handle_arrow_down(model)

      {:event, %{type: @event_resize, h: h}} ->
        %{model | window_height: h}

      _ ->
        model
    end
  end

  defp handle_arrow_up(%{view_mode: :dashboard} = model) do
    %{model | selected_index: max(model.selected_index - 1, 0)}
  end

  defp handle_arrow_up(%{view_mode: :output} = model) do
    %{model | output_scroll: max(model.output_scroll - 1, 0), output_auto_scroll: false}
  end

  defp handle_arrow_down(%{view_mode: :dashboard} = model) do
    max_idx = max(model.total_jobs - 1, 0)
    %{model | selected_index: min(model.selected_index + 1, max_idx)}
  end

  defp handle_arrow_down(%{view_mode: :output} = model) do
    %{model | output_scroll: model.output_scroll + 1, output_auto_scroll: false}
  end

  @impl true
  def render(model) do
    case model.view_mode do
      :dashboard -> render_dashboard(model)
      :output -> render_output(model)
    end
  end

  defp render_dashboard(model) do
    view(top_bar: top_bar(model), bottom_bar: dashboard_bottom_bar()) do
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

  defp render_output(model) do
    lines = String.split(model.selected_job_output, "\n")

    output_elements =
      case lines do
        [""] ->
          [label(content: "  (no output yet)", color: :black)]

        _ ->
          Enum.map(lines, fn line ->
            label(content: line)
          end)
      end

    view(top_bar: output_top_bar(model), bottom_bar: output_bottom_bar()) do
      panel title: output_panel_title(model) do
        viewport offset_y: model.output_scroll do
          output_elements
        end
      end
    end
  end

  defp output_top_bar(model) do
    bar do
      label(
        content:
          " codex-subagents | viewing output | up #{format_uptime(model.started_at)} | running #{model.running}/#{model.max_concurrency} | queued #{model.queued}"
      )
    end
  end

  defp output_bottom_bar do
    bar do
      label(content: " esc back | arrows scroll | q quit")
    end
  end

  defp output_panel_title(model) do
    job = find_selected_job(model)

    if job do
      id = truncate_id(job.id)
      label_part = if job.label, do: " [#{job.label}]", else: ""
      status_part = "#{status_icon(job.status)} #{job.status}"
      duration = format_duration(job)
      "Output: #{id}#{label_part} #{status_part} #{duration}"
    else
      "Output"
    end
  end

  defp find_selected_job(model) do
    Enum.find(model.all_jobs, &(&1.id == model.selected_job_id))
  end

  defp fetch_state(%__MODULE__{} = model) do
    case :rpc.call(model.daemon, CodexSubagents.Registry, :dashboard_state, []) do
      {:ok, data} ->
        all_jobs =
          data.jobs_by_owner
          |> Enum.flat_map(& &1.jobs)

        %__MODULE__{
          model
          | started_at: data.started_at,
            jobs_by_owner: data.jobs_by_owner,
            all_jobs: all_jobs,
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

  defp fetch_output(%__MODULE__{} = model) do
    case :rpc.call(model.daemon, CodexSubagents.Registry, :read_output, [model.selected_job_id]) do
      {:ok, content} ->
        scroll =
          if model.output_auto_scroll do
            line_count = content |> String.split("\n") |> length()
            visible = output_visible_lines(model)
            max(0, line_count - visible)
          else
            model.output_scroll
          end

        %{model | selected_job_output: content, output_scroll: scroll}

      _ ->
        model
    end
  end

  defp output_visible_lines(model) do
    default = 24
    height = model.window_height || default
    height - 4
  end

  defp top_bar(model) do
    bar do
      label(
        content:
          " codex-subagents | up #{format_uptime(model.started_at)} | running #{model.running}/#{model.max_concurrency} | queued #{model.queued}"
      )
    end
  end

  defp dashboard_bottom_bar do
    bar do
      label(content: " q quit | arrows navigate | enter view output")
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
    {elements, _idx} =
      model.jobs_by_owner
      |> Enum.with_index()
      |> Enum.reduce({[], 0}, fn {owner_group, group_idx}, {acc, job_idx} ->
        header = owner_header(owner_group.owner, length(owner_group.jobs), group_idx == 0)

        {rows, next_idx} =
          owner_job_rows(owner_group.jobs, model.selected_index, job_idx)

        {acc ++ header ++ rows, next_idx}
      end)

    elements
  end

  defp owner_header(owner, count, first?) do
    spacer =
      if first?,
        do: [],
        else: [label(content: "")]

    spacer ++
      [label(content: "Owner: #{owner} (#{count} jobs)")]
  end

  defp owner_job_rows(jobs, selected_index, start_idx) do
    {rows, next_idx} =
      jobs
      |> Enum.with_index()
      |> Enum.map(fn {job, i} ->
        global_idx = start_idx + i
        selected? = global_idx == selected_index

        row =
          if selected? do
            label(content: job_line(job), color: status_color(job.status), background: :blue)
          else
            label(content: job_line(job), color: status_color(job.status))
          end

        {row, global_idx}
      end)
      |> Enum.unzip()

    {rows, (List.first(next_idx) || start_idx) + length(jobs)}
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
