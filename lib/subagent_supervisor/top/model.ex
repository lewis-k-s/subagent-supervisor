defmodule SubagentSupervisor.Top.Model do
  @moduledoc false

  import Ratatouille.Constants, only: [key: 1, event_type: 1]

  alias Ratatouille.Runtime.Subscription

  @key_esc key(:esc)
  @key_enter key(:enter)
  @key_arrow_up key(:arrow_up)
  @key_arrow_down key(:arrow_down)
  @key_page_up key(:pgup)
  @key_page_down key(:pgdn)
  @key_home key(:home)
  @key_end key(:end)
  @event_mouse event_type(:mouse)
  @mouse_wheel_up key(:mouse_wheel_up)
  @mouse_wheel_down key(:mouse_wheel_down)
  @event_resize event_type(:resize)

  @mouse_wheel_debounce_ms 50
  @output_buffer 100

  # Vertical: 2 bars (top + bottom) + 2 panel border + 2 panel padding
  @output_v_chrome 6

  alias SubagentSupervisor.Top

  def init(%{daemon: daemon, window: %{height: height, width: width}}) do
    model = %Top{daemon: daemon, window_height: height, window_width: width}
    fetch_state(model)
  end

  def init(%{daemon: daemon}) do
    model = %Top{daemon: daemon}
    fetch_state(model)
  end

  def init(%{window: %{height: height, width: width}}) do
    daemon = Application.fetch_env!(:subagent_supervisor, :top_daemon)
    model = %Top{daemon: daemon, window_height: height, window_width: width}
    fetch_state(model)
  end

  def subscribe(_model) do
    Subscription.interval(250, :tick)
  end

  def update(model, msg) do
    case msg do
      :tick ->
        model =
          if model.view_mode == :output and model.selected_job_id do
            model
          else
            fetch_state(model)
          end

        model =
          if model.view_mode == :output and model.selected_job_id do
            fetch_output(model)
          else
            model
          end

        if model.flash_until && DateTime.compare(model.flash_until, DateTime.utc_now()) != :gt do
          %{model | flash_until: nil, flash_index: nil}
        else
          model
        end

      {:event, %{ch: ?q}} ->
        if model.view_mode == :dashboard do
          System.halt(0)
        else
          model
        end

      {:event, %{ch: ?r}} ->
        if model.view_mode == :output do
          %{
            model
            | output_verbose: not model.output_verbose,
              output_byte_offset: 0,
              selected_job_output: []
          }
        else
          model
        end

      {:event, %{ch: ?C}} ->
        if model.view_mode in [:dashboard, :session_detail] do
          handle_copy(model)
        else
          model
        end

      {:event, %{key: @key_esc}} ->
        if model.view_mode in [:output, :session_detail] do
          if recent_mouse_wheel?(model) do
            %{model | last_mouse_wheel_at: nil}
          else
            %{
              model
              | view_mode: :dashboard,
                selected_job_id: nil,
                selected_job_output: [],
                output_verbose: false,
                output_scroll: 0,
                output_byte_offset: 0
            }
          end
        else
          model
        end

      {:event, %{key: @key_enter}} ->
        if model.view_mode == :dashboard do
          case Enum.at(model.navigable_rows, model.selected_index) do
            {:job, job} ->
              model = %{
                model
                | view_mode: :output,
                  selected_job_id: job.id,
                  output_scroll: 0,
                  output_auto_scroll: true,
                  output_byte_offset: 0,
                  selected_job_output: []
              }

              fetch_output(model)

            {:owner, _} ->
              model

            nil ->
              model
          end
        else
          model
        end

      {:event, %{key: @key_arrow_up}} ->
        handle_arrow_up(model)

      {:event, %{key: @key_arrow_down}} ->
        handle_arrow_down(model)

      {:event, %{type: @event_mouse, key: @mouse_wheel_up}} ->
        handle_arrow_up(model) |> touch_mouse_wheel()

      {:event, %{type: @event_mouse, key: @mouse_wheel_down}} ->
        handle_arrow_down(model) |> touch_mouse_wheel()

      {:event, %{key: @key_page_up}} ->
        handle_page_up(model)

      {:event, %{key: @key_page_down}} ->
        handle_page_down(model)

      {:event, %{key: @key_home}} ->
        handle_home(model)

      {:event, %{key: @key_end}} ->
        handle_end(model)

      {:event, %{type: @event_resize, h: h, w: w}} ->
        %{model | window_height: h, window_width: w}

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
    max_idx = max(length(model.navigable_rows) - 1, 0)
    %{model | selected_index: min(model.selected_index + 1, max_idx)}
  end

  defp handle_arrow_down(%{view_mode: :output} = model) do
    %{model | output_scroll: model.output_scroll + 1, output_auto_scroll: false}
  end

  defp handle_page_up(%{view_mode: :output} = model) do
    page = output_visible_lines(model)
    %{model | output_scroll: max(model.output_scroll - page, 0), output_auto_scroll: false}
  end

  defp handle_page_up(%{view_mode: :dashboard} = model) do
    page = dashboard_visible_jobs(model)
    %{model | selected_index: max(model.selected_index - page, 0)}
  end

  defp handle_page_down(%{view_mode: :output} = model) do
    page = output_visible_lines(model)
    %{model | output_scroll: model.output_scroll + page, output_auto_scroll: false}
  end

  defp handle_page_down(%{view_mode: :dashboard} = model) do
    page = dashboard_visible_jobs(model)
    max_idx = max(length(model.navigable_rows) - 1, 0)
    %{model | selected_index: min(model.selected_index + page, max_idx)}
  end

  defp handle_home(%{view_mode: :output} = model) do
    %{model | output_scroll: 0, output_auto_scroll: false}
  end

  defp handle_home(%{view_mode: :dashboard} = model) do
    %{model | selected_index: 0}
  end

  defp handle_end(%{view_mode: :output} = model) do
    %{model | output_auto_scroll: true}
  end

  defp handle_end(%{view_mode: :dashboard} = model) do
    %{model | selected_index: max(length(model.navigable_rows) - 1, 0)}
  end

  defp fetch_state(%Top{} = model) do
    case :rpc.call(model.daemon, SubagentSupervisor.Registry, :dashboard_state, []) do
      {:ok, data} ->
        all_jobs =
          data.jobs_by_owner
          |> Enum.flat_map(& &1.jobs)

        navigable_rows =
          data.jobs_by_owner
          |> Enum.flat_map(fn group ->
            [{:owner, group.owner}] ++ Enum.map(group.jobs, &{:job, &1})
          end)

        max_nav = max(length(navigable_rows) - 1, 0)
        clamped = min(model.selected_index, max_nav)

        %Top{
          model
          | started_at: data.started_at,
            jobs_by_owner: data.jobs_by_owner,
            all_jobs: all_jobs,
            total_jobs: data.total_jobs,
            running: data.running,
            queued: data.queued,
            max_concurrency: data.max_concurrency,
            supervision_tree: data.supervision_tree,
            navigable_rows: navigable_rows,
            selected_index: clamped,
            error: nil
        }

      {:badrpc, reason} ->
        %{model | error: "daemon unreachable: #{inspect(reason)}"}
    end
  end

  defp fetch_output(%Top{} = model) do
    case :rpc.call(model.daemon, SubagentSupervisor.Registry, :read_output, [
           model.selected_job_id
         ]) do
      {:ok, raw_content} ->
        format_fn =
          if model.output_verbose do
            :format_verbose_incremental
          else
            :format_incremental
          end

        {new_tagged, new_offset} =
          :rpc.call(
            model.daemon,
            SubagentSupervisor.StreamJSON,
            format_fn,
            [raw_content, model.output_byte_offset]
          )

        new_tagged =
          case new_tagged do
            list when is_list(list) -> list
            _ -> []
          end

        new_offset =
          case new_offset do
            offset when is_integer(offset) -> offset
            _ -> model.output_byte_offset
          end

        flattened = flatten_tagged_lines(new_tagged)
        appended_output = model.selected_job_output ++ flattened

        {trimmed_output, scroll_adj} = trim_output(appended_output, model)

        scroll =
          if model.output_auto_scroll do
            line_count = length(trimmed_output)
            visible = output_visible_lines(model)
            max(0, line_count - visible)
          else
            max(model.output_scroll - scroll_adj, 0)
          end

        %{
          model
          | selected_job_output: trimmed_output,
            output_scroll: scroll,
            output_byte_offset: new_offset
        }

      _ ->
        model
    end
  end

  defp flatten_tagged_lines(tagged) do
    Enum.flat_map(tagged, fn {text, color} ->
      text
      |> String.split("\n")
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&{&1, color})
    end)
  end

  defp trim_output(output, model) do
    visible = output_visible_lines(model)
    max_lines = visible + @output_buffer

    if length(output) > max_lines do
      trimmed_count = length(output) - max_lines
      {Enum.take(output, -max_lines), trimmed_count}
    else
      {output, 0}
    end
  end

  defp output_visible_lines(model) do
    default = 24
    height = model.window_height || default
    max(height - @output_v_chrome, 1)
  end

  defp dashboard_visible_jobs(model) do
    default = 24
    height = model.window_height || default
    max(height - sup_panel_height(model) - 6, 3)
  end

  defp sup_panel_height(model) do
    tree_size = count_tree_nodes(model.supervision_tree)
    default_height = model.window_height || 24
    max_allowed = max(default_height - 8, 8)
    min(max(tree_size + 4, 6), min(12, max_allowed))
  end

  defp count_tree_nodes(tree) do
    Enum.reduce(tree, 0, fn node, acc ->
      acc + 1 + count_tree_nodes(Map.get(node, :children, []))
    end)
  end

  defp handle_copy(model) do
    case Enum.at(model.navigable_rows, model.selected_index) do
      {:job, job} ->
        copy_to_clipboard(job.id)
        set_flash(model)

      {:owner, owner} ->
        copy_to_clipboard(owner)
        set_flash(model)

      nil ->
        model
    end
  end

  defp copy_to_clipboard(text) do
    port = Port.open({:spawn, "pbcopy"}, [:binary])
    Port.command(port, text)
    Port.close(port)
  end

  defp set_flash(model) do
    %{
      model
      | flash_until: DateTime.utc_now() |> DateTime.add(1, :second),
        flash_index: model.selected_index
    }
  end

  defp touch_mouse_wheel(model) do
    %{model | last_mouse_wheel_at: System.monotonic_time(:millisecond)}
  end

  defp recent_mouse_wheel?(%{last_mouse_wheel_at: nil}), do: false

  defp recent_mouse_wheel?(%{last_mouse_wheel_at: ts}) do
    System.monotonic_time(:millisecond) - ts < @mouse_wheel_debounce_ms
  end
end
