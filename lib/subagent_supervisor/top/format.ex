defmodule SubagentSupervisor.Top.Format do
  @moduledoc false

  @doc false
  def status_icon(:running), do: "\u25CF"
  def status_icon(:queued), do: "\u25CB"
  def status_icon(:succeeded), do: "\u2713"
  def status_icon(:failed), do: "\u2717"
  def status_icon(:registered), do: "\u25C9"

  @doc false
  def status_color(:running), do: :yellow
  def status_color(:queued), do: :black
  def status_color(:succeeded), do: :green
  def status_color(:failed), do: :red
  def status_color(:registered), do: :magenta
  def status_color(_), do: :white

  @doc false
  def format_duration(%{status: :queued}), do: ""

  def format_duration(%{status: :registered, inserted_at: inserted_at})
      when not is_nil(inserted_at) do
    format_time_diff(inserted_at)
  end

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

  defp format_time_diff(from) do
    diff = DateTime.diff(DateTime.utc_now(), from, :second)

    cond do
      diff < 60 -> "#{diff}s"
      diff < 3600 -> "#{div(diff, 60)}m#{rem(diff, 60)}s"
      true -> "#{div(diff, 3600)}h#{rem(diff, 3600) |> div(60)}m"
    end
  end

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
  def truncate_command(nil), do: ""
  def truncate_command(cmd) when byte_size(cmd) > 40, do: String.slice(cmd, 0, 37) <> "..."
  def truncate_command(cmd), do: cmd

  @doc false
  def format_pid_short("not started"), do: "(not started)"
  def format_pid_short(pid_str), do: "(#{pid_str})"
end
