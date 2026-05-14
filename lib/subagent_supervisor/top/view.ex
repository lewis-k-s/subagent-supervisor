defmodule SubagentSupervisor.Top.View do
  @moduledoc false

  import Ratatouille.View
  alias SubagentSupervisor.Top.Format

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
    all_lines = String.split(model.selected_job_output, "\n")
    total_lines = length(all_lines)
    visible = output_visible_lines(model)
    content_width = output_content_width(model)

    output_elements =
      cond do
        all_lines == [""] ->
          pad_labels(
            [label(content: pad_line("  (no output yet)", content_width), color: :black)],
            visible,
            content_width
          )

        total_lines == 0 ->
          pad_labels(
            [label(content: pad_line("  (no output yet)", content_width), color: :black)],
            visible,
            content_width
          )

        true ->
          max_scroll = max(total_lines - visible, 0)
          effective_scroll = min(model.output_scroll, max_scroll)

          start_idx = effective_scroll
          end_idx = min(start_idx + visible, total_lines) - 1

          sliced =
            all_lines
            |> Enum.slice(start_idx..end_idx)
            |> Enum.map(&label(content: pad_line(&1, content_width)))

          pad_labels(sliced, visible, content_width)
      end

    view(top_bar: output_top_bar(model), bottom_bar: output_bottom_bar()) do
      panel title: output_panel_title(model), height: :fill do
        output_elements
      end
    end
  end

  defp output_top_bar(model) do
    bar do
      label(
        content:
          " subagent-supervisor | viewing output | up #{Format.format_uptime(model.started_at)} | running #{model.running}/#{model.max_concurrency} | queued #{model.queued}"
      )
    end
  end

  defp output_bottom_bar do
    bar do
      label(content: " esc back | \u2191\u2193/pgup/pgdn/home/end scroll | r verbose | q quit")
    end
  end

  defp output_panel_title(model) do
    job = find_selected_job(model)

    if job do
      id = Format.truncate_id(job.id)
      label_part = if job.label, do: " [#{job.label}]", else: ""
      status_part = "#{Format.status_icon(job.status)} #{job.status}"
      duration = Format.format_duration(job)
      mode = if model.output_verbose, do: "VERBOSE", else: "parsed"
      "Output: #{id}#{label_part} #{status_part} #{duration} [#{mode}]"
    else
      "Output"
    end
  end

  defp find_selected_job(model) do
    Enum.find(model.all_jobs, &(&1.id == model.selected_job_id))
  end

  defp output_visible_lines(model) do
    default = 24
    height = model.window_height || default
    max(height - 6, 1)
  end

  defp pad_labels(labels, target_count, content_width) do
    current = length(labels)
    blank = label(content: String.duplicate(" ", content_width))

    if current < target_count do
      labels ++ List.duplicate(blank, target_count - current)
    else
      labels
    end
  end

  defp pad_line(line, width) do
    len = String.length(line)

    cond do
      len > width ->
        String.slice(line, 0, width)

      len < width ->
        line <> String.duplicate(" ", width - len)

      true ->
        line
    end
  end

  defp output_content_width(model) do
    default = 80
    width = model.window_width || default
    max(width - 6, 10)
  end

  defp top_bar(model) do
    bar do
      label(
        content:
          " subagent-supervisor | up #{Format.format_uptime(model.started_at)} | running #{model.running}/#{model.max_concurrency} | queued #{model.queued}"
      )
    end
  end

  defp dashboard_bottom_bar do
    bar do
      label(content: " q quit | \u2191\u2193/pgup/pgdn navigate | enter view output")
    end
  end

  defp sup_panel_height(model) do
    tree_size = count_tree_nodes(model.supervision_tree)
    default_height = model.window_height || 24
    max_allowed = max(default_height - 8, 8)
    min(max(tree_size + 4, 6), min(12, max_allowed))
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
    line = "#{indent}#{node.name} #{Format.format_pid_short(Map.get(node, :pid, "not started"))}"

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
            label(
              content: job_line(job),
              color: Format.status_color(job.status),
              background: :blue
            )
          else
            label(content: job_line(job), color: Format.status_color(job.status))
          end

        {row, global_idx}
      end)
      |> Enum.unzip()

    {rows, (List.first(next_idx) || start_idx) + length(jobs)}
  end

  defp job_line(job) do
    [
      "  ",
      Format.status_icon(job.status),
      " ",
      pad(Format.truncate_id(job.id), 12),
      pad(to_string(job.status), 11),
      pad(Format.format_duration(job), 8),
      pad(job.label || "", 14),
      Format.truncate_command(job.command)
    ]
    |> IO.iodata_to_binary()
  end

  defp pad(value, width) do
    value = to_string(value)
    value <> String.duplicate(" ", max(width - String.length(value), 1))
  end

  defp count_tree_nodes(tree) do
    Enum.reduce(tree, 0, fn node, acc ->
      acc + 1 + count_tree_nodes(Map.get(node, :children, []))
    end)
  end
end
