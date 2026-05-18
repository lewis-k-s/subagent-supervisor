defmodule SubagentSupervisor.Registry.Persistence do
  @moduledoc false

  alias SubagentSupervisor.Job
  require Logger

  @snapshot_file "registry.etf"
  @tmp_snapshot_file "registry.etf.tmp"

  @spec state_dir(keyword()) :: String.t()
  def state_dir(opts \\ []) do
    cond do
      dir = Keyword.get(opts, :state_dir) ->
        Path.expand(dir)

      dir = Application.get_env(:subagent_supervisor, :state_dir) ->
        Path.expand(dir)

      dir = System.get_env("SUBAGENT_SUPERVISOR_STATE_DIR") ->
        Path.expand(dir)

      dir = System.get_env("XDG_STATE_HOME") ->
        Path.expand(Path.join(dir, "subagent-supervisor"))

      true ->
        Path.join([System.user_home!(), ".local", "state", "subagent-supervisor"])
    end
  end

  @spec log_dir(String.t()) :: String.t()
  def log_dir(state_dir), do: Path.join(state_dir, "logs")

  @spec log_path(String.t(), String.t()) :: String.t()
  def log_path(state_dir, job_id), do: Path.join(log_dir(state_dir), "#{job_id}.log")

  @spec load(String.t()) :: {:ok, [Job.t()]}
  def load(state_dir) do
    path = snapshot_path(state_dir)

    case File.read(path) do
      {:ok, binary} ->
        decode(binary, path)

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        Logger.warning("could not read registry snapshot #{path}: #{inspect(reason)}")
        {:ok, []}
    end
  end

  @spec save!(String.t(), map()) :: :ok
  def save!(state_dir, jobs) when is_map(jobs) do
    File.mkdir_p!(state_dir)
    File.mkdir_p!(log_dir(state_dir))

    envelope = %{
      version: 1,
      saved_at: DateTime.utc_now(),
      jobs: jobs |> Map.values() |> Enum.map(&Job.to_persisted_map/1)
    }

    binary = :erlang.term_to_binary(envelope, [:compressed])
    path = snapshot_path(state_dir)
    tmp = tmp_snapshot_path(state_dir)

    File.write!(tmp, binary)
    File.rename!(tmp, path)
    :ok
  end

  @spec clear!(String.t()) :: :ok
  def clear!(state_dir) do
    File.rm_rf!(snapshot_path(state_dir))
    File.rm_rf!(tmp_snapshot_path(state_dir))
    File.rm_rf!(log_dir(state_dir))
    File.mkdir_p!(log_dir(state_dir))
    :ok
  end

  defp decode(binary, path) do
    case :erlang.binary_to_term(binary, [:safe]) do
      %{version: 1, jobs: jobs} when is_list(jobs) ->
        {:ok, Enum.map(jobs, &Job.from_persisted_map!/1)}

      other ->
        Logger.warning("ignoring unsupported registry snapshot #{path}: #{inspect(other)}")
        quarantine(path)
        {:ok, []}
    end
  rescue
    error ->
      Logger.warning("ignoring corrupt registry snapshot #{path}: #{Exception.message(error)}")
      quarantine(path)
      {:ok, []}
  end

  defp quarantine(path) do
    if File.exists?(path) do
      suffix = DateTime.utc_now() |> DateTime.to_unix() |> to_string()
      quarantine_path = path <> ".corrupt-" <> suffix
      File.rename(path, quarantine_path)
    end
  rescue
    error ->
      Logger.warning(
        "could not quarantine registry snapshot #{path}: #{Exception.message(error)}"
      )

      :ok
  end

  defp snapshot_path(state_dir), do: Path.join(state_dir, @snapshot_file)
  defp tmp_snapshot_path(state_dir), do: Path.join(state_dir, @tmp_snapshot_file)
end
