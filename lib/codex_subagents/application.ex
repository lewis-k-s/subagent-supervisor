defmodule CodexSubagents.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Task.Supervisor, name: CodexSubagents.TaskSupervisor},
      CodexSubagents.Registry
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: CodexSubagents.Supervisor)
  end
end
