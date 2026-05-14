defmodule SubagentSupervisor.Launcher do
  @moduledoc """
  Resolves the allowed launcher script path(s) for job commands.
  """

  @script_name "claude-subagent"

  @doc """
  Finds the launcher script by checking the escript directory first,
  then the system PATH.

  Returns `{:ok, absolute_path}` or `:error`.
  """
  @spec resolve() :: {:ok, String.t()} | :error
  def resolve do
    with {:error, _} <- resolve_from_escript_dir(),
         {:error, _} <- resolve_from_system_path() do
      :error
    else
      {:ok, path} -> {:ok, path}
    end
  end

  @doc """
  Returns the list of allowed launchers from application config, or
  falls back to resolving the launcher script.
  """
  @spec allowed_launchers() :: [String.t()]
  def allowed_launchers do
    case Application.get_env(:subagent_supervisor, :allowed_launchers) do
      launchers when is_list(launchers) and launchers != [] ->
        launchers

      _ ->
        case resolve() do
          {:ok, path} -> [path]
          :error -> []
        end
    end
  end

  defp resolve_from_escript_dir do
    case :escript.script_name() do
      ~c"" ->
        :error

      name ->
        dir = name |> to_string() |> Path.expand() |> Path.dirname()
        candidate = Path.join([dir, "scripts", @script_name])

        if File.exists?(candidate) do
          {:ok, Path.expand(candidate)}
        else
          :error
        end
    end
  end

  defp resolve_from_system_path do
    case System.find_executable(@script_name) do
      nil -> :error
      path -> {:ok, path}
    end
  end
end
