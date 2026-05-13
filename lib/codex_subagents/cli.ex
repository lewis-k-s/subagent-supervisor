defmodule CodexSubagents.CLI do
  @moduledoc """
  Escript entry point. Parses CLI arguments and dispatches RPC calls to the
  daemon over Erlang distribution.
  """

  @cookie :codex_subagents

  def main(argv) do
    case argv do
      ["server" | rest] -> server(rest)
      ["stop"] -> stop()
      ["session" | rest] -> session(rest)
      ["start" | rest] -> start(rest)
      ["wait" | rest] -> wait(rest)
      ["list" | rest] -> list(rest)
      ["show" | rest] -> show(rest)
      ["help"] -> help()
      ["--help"] -> help()
      [] -> help()
      [unknown | _] -> fail("unknown command: #{unknown}")
    end
  end

  defp server(rest) do
    opts = parse_flags(rest)
    max_concurrency = opts |> Map.get("max-concurrency", "2") |> String.to_integer() |> max(1)
    Application.put_env(:codex_subagents, :max_concurrency, max_concurrency)
    start_node!(:codex_subagents)
    Application.ensure_all_started(:codex_subagents)

    IO.puts(
      "codex-subagents daemon started as #{Node.self()} with max_concurrency=#{max_concurrency}"
    )

    Process.sleep(:infinity)
  rescue
    ArgumentError -> fail("--max-concurrency must be an integer")
  end

  defp stop do
    start_node!(unique_cli_name())
    daemon = daemon_name()

    unless Node.connect(daemon) do
      fail("daemon #{daemon} is not reachable")
    end

    case :rpc.call(daemon, System, :halt, [0]) do
      {:badrpc, :nodedown} -> :ok
      {:badrpc, reason} -> fail("rpc failed: #{inspect(reason)}")
      _ -> :ok
    end
  end

  defp session(rest) do
    opts = parse_flags(rest)
    id = new_session_id(Map.get(opts, "prefix", "session"))

    IO.puts(CodexSubagents.JSON.encode(%{owner: id, session: id}))
  end

  defp start(rest) do
    {flags, command} = split_command(rest)
    opts = parse_flags(flags)

    attrs = %{
      "owner" => session_owner(opts),
      "label" => Map.get(opts, "label"),
      "cwd" => Map.get(opts, "cwd", File.cwd!()),
      "command" => shell_join(command)
    }

    require_option!(attrs, "owner")

    rpc!(CodexSubagents.Registry, :start_job, [attrs])
    |> print_result()
  end

  defp wait(rest) do
    opts = parse_flags(rest)
    owner = session_owner(opts)
    mode = parse_mode(Map.get(opts, "mode", "all"))
    timeout_ms = opts |> Map.get("timeout", "86400") |> String.to_integer() |> Kernel.*(1_000)
    ids = opts |> Map.get("ids", "") |> split_csv()

    if is_nil(owner) and ids == [] do
      fail("wait requires --owner or --ids")
    end

    rpc!(CodexSubagents.Registry, :wait, [owner, ids, mode, timeout_ms])
    |> print_result()
  rescue
    ArgumentError -> fail("--timeout must be an integer number of seconds")
  end

  defp list(rest) do
    opts = parse_flags(rest)

    rpc!(CodexSubagents.Registry, :list, [session_owner(opts)])
    |> print_result()
  end

  defp show([id]) do
    rpc!(CodexSubagents.Registry, :show, [id])
    |> print_result()
  end

  defp show(_), do: fail("usage: codex-subagents show JOB_ID")

  defp rpc!(module, function, args) do
    start_node!(unique_cli_name())
    daemon = daemon_name()

    unless Node.connect(daemon) do
      fail("daemon #{daemon} is not reachable; start it with `codex-subagents server`")
    end

    case :rpc.call(daemon, module, function, args) do
      {:badrpc, reason} -> fail("rpc failed: #{inspect(reason)}")
      result -> result
    end
  end

  defp print_result({:ok, value}) do
    IO.puts(CodexSubagents.JSON.encode(value))
  end

  defp print_result({:error, reason}) do
    fail("error: #{reason}")
  end

  defp start_node!(name) do
    case Node.start(name, :shortnames) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> fail("could not start distributed Erlang node: #{inspect(reason)}")
    end

    Node.set_cookie(@cookie)
  end

  defp daemon_name do
    :"codex_subagents@#{short_hostname()}"
  end

  defp unique_cli_name do
    suffix =
      [System.pid(), random_token(4)]
      |> Enum.join("_")
      |> String.replace(~r/[^A-Za-z0-9_]/, "_")

    :"codex_subagents_cli_#{suffix}"
  end

  defp short_hostname do
    {:ok, hostname} = :inet.gethostname()
    hostname |> to_string() |> String.split(".") |> hd()
  end

  defp split_command(args) do
    case Enum.split_while(args, &(&1 != "--")) do
      {_flags, []} -> fail("missing command separator `--`")
      {flags, [_separator | command]} when command != [] -> {flags, command}
      {_flags, _} -> fail("missing bash command after `--`")
    end
  end

  @doc false
  def parse_flags(args), do: parse_flags(args, %{})

  defp parse_flags([], acc), do: acc

  defp parse_flags(["--" <> key, value | rest], acc) do
    parse_flags(rest, Map.put(acc, key, value))
  end

  defp parse_flags([bad | _], _acc), do: fail("expected --key value flag, got #{bad}")

  @doc false
  def split_csv(""), do: []
  def split_csv(value), do: value |> String.split(",", trim: true) |> Enum.map(&String.trim/1)

  @doc false
  def session_owner(opts), do: Map.get(opts, "owner") || Map.get(opts, "session")

  @doc false
  def new_session_id(prefix \\ "session") do
    prefix = slug(prefix)
    "#{prefix}-#{random_token(5)}"
  end

  defp shell_join(args), do: Enum.map_join(args, " ", &shell_quote/1)

  @doc false
  def shell_quote(arg) do
    if String.match?(arg, ~r/^[A-Za-z0-9_\/.,:=@%+-]+$/) do
      arg
    else
      "'" <> String.replace(arg, "'", "'\"'\"'") <> "'"
    end
  end

  @doc false
  def parse_mode("any"), do: :any
  def parse_mode("all"), do: :all
  def parse_mode(_), do: fail("--mode must be any or all")

  defp random_token(bytes) do
    bytes
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
    |> String.downcase()
  end

  defp slug(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "session"
      slug -> String.slice(slug, 0, 24)
    end
  end

  defp require_option!(attrs, key) do
    if Map.get(attrs, key) in [nil, ""] do
      fail("missing required --#{key}")
    end
  end

  defp help do
    IO.puts("""
    codex-subagents server [--max-concurrency 2]
    codex-subagents stop
    codex-subagents session [--prefix PREFIX]
    codex-subagents start --owner OWNER|--session SESSION [--label LABEL] [--cwd DIR] -- BASH COMMAND
    codex-subagents wait --owner OWNER|--session SESSION [--ids ID,ID] [--mode any|all] [--timeout SECONDS]
    codex-subagents list [--owner OWNER|--session SESSION]
    codex-subagents show JOB_ID
    """)
  end

  defp fail(message) do
    IO.puts(:stderr, message)
    System.halt(1)
  end
end
