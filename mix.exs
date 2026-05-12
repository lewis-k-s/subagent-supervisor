defmodule CodexSubagents.MixProject do
  use Mix.Project

  def project do
    [
      app: :codex_subagents,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      escript: [main_module: CodexSubagents.CLI, name: "codex-subagents"],
      deps: []
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {CodexSubagents.Application, []}
    ]
  end
end
