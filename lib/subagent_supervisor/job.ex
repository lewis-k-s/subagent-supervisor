defmodule SubagentSupervisor.Job do
  @moduledoc """
  Immutable job metadata tracked by the daemon.
  """

  @enforce_keys [:id, :owner, :command, :cwd, :status, :inserted_at]
  defstruct [
    :id,
    :owner,
    :command,
    :cwd,
    :label,
    :agent,
    :sandbox_write_roots,
    :sandbox_write_bounded,
    :cwd_writable,
    :server_sandbox,
    :status,
    :exit_status,
    :output,
    :output_path,
    :session_id,
    :task_ref,
    :inserted_at,
    :started_at,
    :finished_at
  ]

  @type t :: %__MODULE__{}

  @persisted_fields [
    :id,
    :owner,
    :command,
    :cwd,
    :label,
    :agent,
    :sandbox_write_roots,
    :sandbox_write_bounded,
    :cwd_writable,
    :server_sandbox,
    :status,
    :exit_status,
    :output,
    :output_path,
    :session_id,
    :inserted_at,
    :started_at,
    :finished_at
  ]

  @max_persisted_output 4_000

  @doc """
  Converts a job to durable metadata.

  Runtime-only ownership fields such as task refs, pids, ports, and monitors
  are intentionally omitted; they are only valid for the current daemon
  lifetime.
  """
  @spec to_persisted_map(t()) :: map()
  def to_persisted_map(%__MODULE__{} = job) do
    job
    |> Map.from_struct()
    |> Map.take(@persisted_fields)
    |> Map.update(:output, nil, &persisted_output/1)
  end

  @doc """
  Rebuilds a job from durable metadata.
  """
  @spec from_persisted_map!(map()) :: t()
  def from_persisted_map!(map) when is_map(map) do
    attrs = normalize_keys(map)

    struct!(
      __MODULE__,
      attrs
      |> Map.take(@persisted_fields)
      |> Map.put(:task_ref, nil)
    )
  end

  defp normalize_keys(map) do
    Map.new(map, fn
      {key, value} when is_binary(key) -> {String.to_existing_atom(key), value}
      {key, value} when is_atom(key) -> {key, value}
    end)
  end

  defp persisted_output(nil), do: nil

  defp persisted_output(output) when byte_size(output) <= @max_persisted_output, do: output

  defp persisted_output(output) do
    length = String.length(output)
    String.slice(output, max(length - @max_persisted_output, 0), @max_persisted_output)
  end
end
