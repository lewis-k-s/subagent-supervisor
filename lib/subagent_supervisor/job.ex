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
end
