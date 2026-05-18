defmodule SubagentSupervisor.Top.View do
  @moduledoc false

  import Ratatouille.View
  alias SubagentSupervisor.Top.Format

  # Vertical: 2 bars (top + bottom) + 2 panel border + 2 panel padding
  @output_v_chrome 6
  # Horizontal: 2 panel border + 2 panel padding
  @output_h_chrome 4

  @min_width 40
  @min_height 12

  def render(model) do
    if too_small?(model) do
      render_too_small(model)
    else
      case model.view_mode do
        :dashboard -> render_dashboard(model)
        :output -> render_output(model)
        :session_detail -> render_session_detail(model)
      end
    end
  end

  defp too_small?(model) do
    h = model.window_height || 0
    w = model.window_width || 0
    h < @min_height or w < @min_width
  end

  defp render_too_small(_model) do
    view do
      label(content: "Window too small (need #{@min_width}x#{@min_height})")
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
                [column_header()] ++ render_jobs(model)
              end
            end
          end
        end
      end
    end
  end

  defp render_output(model) do
    job = find_selected_job(model)
    content_width = output_content_width(model)
    output_lines = model.selected_job_output

    status_row =
      if job,
        do: [{"#{Format.status_icon(job.status)} #{job.status}", Format.status_color(job.status)}],
        else: []

    prompt = prompt_header(job, content_width)
    header = status_row ++ prompt
    all_lines = header ++ output_lines
    total_lines = length(all_lines)
    visible = output_visible_lines(model)

    output_elements =
      cond do
        output_lines == [] and prompt == [] ->
          pad_labels(
            [label(content: pad_line("  (no output yet)", content_width), color: :black)],
            visible,
            content_width
          )

        true ->
          max_scroll = max(total_lines - visible, 0)

          effective_scroll =
            if model.output_auto_scroll,
              do: max_scroll,
              else: min(model.output_scroll, max_scroll)

          start_idx = effective_scroll
          end_idx = min(start_idx + visible, total_lines) - 1

          rendered =
            all_lines
            |> Enum.slice(start_idx..end_idx)
            |> Enum.take(visible)
            |> Enum.map(fn {line, color} ->
              label(content: pad_line(line, content_width), color: color)
            end)

          pad_labels(rendered, visible, content_width)
      end

    view(top_bar: output_top_bar(model), bottom_bar: output_bottom_bar()) do
      panel title: output_panel_title(model), height: :fill do
        output_elements
      end
    end
  end

  defp render_session_detail(model) do
    job = find_selected_job(model)
    content_width = output_content_width(model)

    if job do
      child_jobs =
        model.all_jobs
        |> Enum.filter(&(&1.owner == job.owner and &1.id != job.id))

      metadata_lines = session_metadata_lines(job, child_jobs, content_width)
      visible = output_visible_lines(model)

      rendered =
        metadata_lines
        |> Enum.take(visible)
        |> Enum.map(fn {line, color} ->
          label(content: pad_line(line, content_width), color: color)
        end)

      elements = pad_labels(rendered, visible, content_width)

      view(top_bar: session_detail_top_bar(model), bottom_bar: session_detail_bottom_bar()) do
        panel title: session_detail_title(job), height: :fill do
          elements
        end
      end
    else
      view(top_bar: session_detail_top_bar(model), bottom_bar: session_detail_bottom_bar()) do
        panel title: "Session Detail", height: :fill do
          label(content: "  Session not found", color: :red)
        end
      end
    end
  end

  defp session_metadata_lines(job, child_jobs, width) do
    lines = [
      {"  Owner:        #{job.owner}", :white},
      {"  Session ID:   #{job.session_id || "(none)"}", :white},
      {"  Label:        #{job.label || "(none)"}", :white},
      {"  CWD:          #{job.cwd || "(unknown)"}", :white},
      {"  Registered:   #{format_datetime(job.inserted_at)}", :white}
    ]

    lines =
      lines ++
        [
          {String.duplicate("─", width), :black},
          {"  Child Jobs (#{length(child_jobs)})", :cyan}
        ]

    if child_jobs == [] do
      lines ++ [{"    (no child jobs)", :black}]
    else
      header =
        {"    #{pad("ID", 12)}#{pad("STATUS", 11)}#{pad("DURATION", 8)}#{pad("LABEL", 14)}COMMAND",
         :cyan}

      child_lines =
        Enum.map(child_jobs, fn child ->
          {"  #{Format.status_icon(child.status)} #{pad(Format.truncate_id(child.id), 12)}#{pad(to_string(child.status), 11)}#{pad(Format.format_duration(child), 8)}#{pad(child.label || "", 14)}#{Format.truncate_command(child.command)}",
           Format.status_color(child.status)}
        end)

      lines ++ [header] ++ child_lines
    end
  end

  defp format_datetime(nil), do: "(unknown)"
  defp format_datetime(dt), do: DateTime.to_string(dt) |> String.replace("Z", " UTC")

  defp session_detail_top_bar(model) do
    bar do
      label(
        content:
          " subagent-supervisor | session detail | up #{Format.format_uptime(model.started_at)} | running #{model.running}/#{model.max_concurrency} | queued #{model.queued}",
        color: :white,
        background: :blue
      )
    end
  end

  defp session_detail_bottom_bar do
    bar do
      label(
        content: " esc back | C copy id | q quit",
        color: :black,
        background: :white
      )
    end
  end

  defp session_detail_title(job) do
    id = Format.truncate_id(job.id)
    label_part = if job.label, do: " [#{job.label}]", else: ""
    "Session: #{id}#{label_part} (#{job.owner})"
  end

  defp output_top_bar(model) do
    bar do
      label(
        content:
          " subagent-supervisor | viewing output | up #{Format.format_uptime(model.started_at)} | running #{model.running}/#{model.max_concurrency} | queued #{model.queued}",
        color: :white,
        background: :blue
      )
    end
  end

  defp output_bottom_bar do
    bar do
      label(
        content: " esc back | \u2191\u2193/pgup/pgdn/home/end scroll | r verbose | q quit",
        color: :black,
        background: :white
      )
    end
  end

  defp output_panel_title(model) do
    job = find_selected_job(model)

    if job do
      id = Format.truncate_id(job.id)
      label_part = if job.label, do: " [#{job.label}]", else: ""
      duration = Format.format_duration(job)
      mode = if model.output_verbose, do: "VERBOSE", else: "parsed"
      "Output: #{id}#{label_part} #{duration} [#{mode}]"
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
    max(height - @output_v_chrome, 1)
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
    max(width - @output_h_chrome, 10)
  end

  defp top_bar(model) do
    bar do
      label(
        content:
          " subagent-supervisor | up #{Format.format_uptime(model.started_at)} | running #{model.running}/#{model.max_concurrency} | queued #{model.queued}",
        color: :white,
        background: :blue
      )
    end
  end

  defp dashboard_bottom_bar do
    bar do
      label(
        content:
          " q quit | \u2191\u2193/pgup/pgdn navigate | enter view output/session | C copy id",
        color: :black,
        background: :white
      )
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
    |> Enum.map(fn {text, color} -> label(content: text, color: color) end)
  end

  defp tree_lines(node, depth \\ 0) do
    indent = String.duplicate("  ", depth)
    pid = Format.format_pid_short(Map.get(node, :pid, "not started"))
    line = "#{indent}#{node.name} #{pid}"
    color = if Map.get(node, :children, []) != [], do: :green, else: :cyan

    [{line, color} | Enum.flat_map(Map.get(node, :children, []), &tree_lines(&1, depth + 1))]
  end

  defp render_jobs(model) do
    owner_counts =
      model.jobs_by_owner
      |> Enum.into(%{}, fn group -> {group.owner, length(group.jobs)} end)

    model.navigable_rows
    |> Enum.with_index()
    |> Enum.flat_map(fn {row, idx} ->
      selected? = idx == model.selected_index
      flashing? = model.flash_index == idx and model.flash_until != nil

      case row do
        {:owner, owner} ->
          count = Map.get(owner_counts, owner, 0)
          [render_owner_header(owner, count, selected?, flashing?)]

        {:job, job} ->
          [render_job_row(job, selected?, flashing?)]
      end
    end)
  end

  defp render_owner_header(owner, count, selected?, flashing?) do
    text = "Owner: #{owner} (#{count} jobs)"

    cond do
      flashing? ->
        bg = flash_background()
        label(content: text, color: :white, background: bg)

      selected? ->
        label(content: text, color: :white, background: :blue)

      true ->
        label(content: text, color: :magenta)
    end
  end

  defp render_job_row(job, selected?, flashing?) do
    cond do
      flashing? ->
        bg = flash_background()
        label(content: job_line(job), color: Format.status_color(job.status), background: bg)

      selected? ->
        label(content: job_line(job), color: Format.status_color(job.status), background: :blue)

      true ->
        label(content: job_line(job), color: Format.status_color(job.status))
    end
  end

  defp flash_background do
    if rem(System.system_time(:millisecond), 500) < 250, do: :blue, else: :cyan
  end

  defp job_line(%{status: :registered, session_id: session_id} = job) do
    display = session_id || "session"

    [
      "  ",
      Format.status_icon(job.status),
      " ",
      pad(Format.truncate_id(job.id), 12),
      pad(to_string(job.status), 11),
      pad(Format.format_duration(job), 8),
      pad(job.label || "", 14),
      Format.truncate_command(display)
    ]
    |> IO.iodata_to_binary()
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

  defp column_header do
    label(
      content:
        "    " <>
          pad("ID", 12) <>
          pad("STATUS", 11) <> pad("DURATION", 8) <> pad("LABEL", 14) <> "COMMAND",
      color: :cyan
    )
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

  defp prompt_header(nil, _width), do: []
  defp prompt_header(%{command: nil}, _width), do: []
  defp prompt_header(%{command: ""}, _width), do: []

  defp prompt_header(%{command: command}, width) do
    wrapped = wrap_text(command, width)

    [{divider("Input", width), :cyan}] ++
      Enum.map(wrapped, &{&1, :yellow}) ++
      [{divider("Output", width), :cyan}]
  end

  defp divider(label, width) do
    prefix = "── #{label} "
    prefix <> String.duplicate("─", max(width - String.length(prefix), 0))
  end

  defp wrap_text(text, width) do
    text
    |> String.split("\n")
    |> Enum.flat_map(&wrap_line(&1, width))
  end

  defp wrap_line(line, width) do
    if String.length(line) <= width do
      [line]
    else
      do_word_wrap(String.split(line), width, [], "")
    end
  end

  defp do_word_wrap([], _width, lines, ""), do: Enum.reverse(lines)
  defp do_word_wrap([], _width, lines, current), do: Enum.reverse([current | lines])

  defp do_word_wrap([word | rest], width, lines, "") do
    do_word_wrap(rest, width, lines, word)
  end

  defp do_word_wrap([word | rest], width, lines, current) do
    if String.length(current) + 1 + String.length(word) <= width do
      do_word_wrap(rest, width, lines, "#{current} #{word}")
    else
      do_word_wrap(rest, width, [current | lines], word)
    end
  end
end
