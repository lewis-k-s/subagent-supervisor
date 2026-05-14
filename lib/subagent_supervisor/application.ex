defmodule SubagentSupervisor.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Task.Supervisor, name: SubagentSupervisor.TaskSupervisor},
      SubagentSupervisor.Registry
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: SubagentSupervisor.Supervisor)
  end
end
