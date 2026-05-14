defmodule SubagentSupervisor.MixProject do
  use Mix.Project

  def project do
    [
      app: :subagent_supervisor,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      escript: [main_module: SubagentSupervisor.CLI, name: "subagent-supervisor"],
      releases: [
        subagent_supervisor: [
          applications: [
            subagent_supervisor: :load
          ],
          include_executables_for: [:unix]
        ]
      ],
      deps: [{:jason, "~> 1.4"}, {:ratatouille, "~> 0.5.0"}],
      config_path: "config/config.exs"
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {SubagentSupervisor.Application, []}
    ]
  end
end
