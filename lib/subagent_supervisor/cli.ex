defmodule SubagentSupervisor.CLI do
  @moduledoc """
  Escript entry point. Parses CLI arguments and dispatches RPC calls to the
  daemon over Erlang distribution.
  """

  require Logger

  @cookie :subagent_supervisor
  @termbox_compatible_terms ["xterm", "screen", "rxvt", "linux", "Eterm", "cygwin"]

  def main(argv) do
    case argv do
      ["server" | rest] -> server(rest)
      ["stop"] -> stop()
      ["session" | rest] -> session(rest)
      ["start" | rest] -> start(rest)
      ["wait" | rest] -> wait(rest)
      ["list" | rest] -> list(rest)
      ["show" | rest] -> show(rest)
      ["status" | rest] -> status_cmd(rest)
      ["tail" | rest] -> tail_cmd(rest)
      ["agents" | rest] -> agents(rest)
      ["top"] -> top()
      ["help"] -> help()
      ["--help"] -> help()
      [] -> help()
      [unknown | _] -> fail("unknown command: #{unknown}")
    end
  end

  defp server(rest) do
    opts = parse_flags(rest)
    max_concurrency = opts |> Map.get("max-concurrency", "2") |> String.to_integer() |> max(1)
    Application.put_env(:subagent_supervisor, :max_concurrency, max_concurrency)
    start_node!(:subagent_supervisor)
    Application.ensure_all_started(:subagent_supervisor)

    IO.puts(
      "subagent-supervisor daemon started as #{Node.self()} with max_concurrency=#{max_concurrency}"
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

    IO.puts(SubagentSupervisor.JSON.encode(%{owner: id, session: id}))
  end

  defp agents(rest) do
    opts = parse_flags(rest)
    cwd = Map.get(opts, "cwd", File.cwd!())

    agents =
      SubagentSupervisor.Agents.discover(cwd)
      |> Enum.map(fn agent ->
        %{
          name: agent.name,
          description: agent.description,
          source: agent.source
        }
      end)

    IO.puts(SubagentSupervisor.JSON.encode(agents))
  end

  defp start(rest) do
    {flags, prompt_args} = split_command(rest)

    unless prompt_args != [] do
      fail("missing prompt after `--`")
    end

    opts = parse_flags(flags)
    agent_name = Map.get(opts, "agent")
    cwd = Map.get(opts, "cwd", File.cwd!())

    if agent_name do
      case SubagentSupervisor.Agents.validate(agent_name, cwd) do
        {:ok, _} ->
          :ok

        {:error, {:not_found, name}} ->
          available =
            SubagentSupervisor.Agents.discover(cwd)
            |> Enum.map(& &1.name)
            |> Enum.sort()
            |> Enum.join(", ")

          fail(
            "unknown agent: #{name}" <>
              if(available != "", do: " (available: #{available})", else: "")
          )
      end
    end

    launcher =
      resolve_launcher!()

    launcher_args =
      if agent_name,
        do: ["--agent", agent_name | prompt_args],
        else: prompt_args

    command = shell_join([launcher | launcher_args])

    attrs = %{
      "owner" => session_owner(opts),
      "label" => Map.get(opts, "label"),
      "agent" => agent_name,
      "cwd" => cwd,
      "command" => command
    }

    require_option!(attrs, "owner")

    rpc!(SubagentSupervisor.Registry, :start_job, [attrs])
    |> print_result()
  end

  defp resolve_launcher! do
    case SubagentSupervisor.Launcher.resolve() do
      {:ok, path} -> path
      :error -> fail("claude-subagent script not found on PATH or next to escript")
    end
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

    rpc!(SubagentSupervisor.Registry, :wait, [owner, ids, mode, timeout_ms])
    |> print_result()
  rescue
    ArgumentError -> fail("--timeout must be an integer number of seconds")
  end

  defp list(rest) do
    opts = parse_flags(rest)

    rpc!(SubagentSupervisor.Registry, :list, [session_owner(opts)])
    |> print_result()
  end

  defp show(args) do
    {id, full?} = parse_show_args(args)

    opts = if full?, do: [include_output: true], else: []

    rpc!(SubagentSupervisor.Registry, :show, [id, opts])
    |> print_result()
  end

  defp parse_show_args(args) do
    full? = "--full" in args
    args = Enum.reject(args, &(&1 == "--full"))

    id =
      case args do
        [id] -> id
        _ -> fail("usage: subagent-supervisor show JOB_ID [--full]")
      end

    {id, full?}
  end

  defp status_cmd(args) do
    if "--summarize" in args do
      fail("--summarize is not yet implemented")
    end

    args = Enum.reject(args, &(&1 == "--summarize"))

    id =
      case args do
        [id] -> id
        _ -> fail("usage: subagent-supervisor status JOB_ID [--summarize]")
      end

    rpc!(SubagentSupervisor.Registry, :status, [id])
    |> print_result()
  end

  defp tail_cmd(args) do
    {id, follow?, verbose?} = parse_tail_args(args)
    daemon = ensure_daemon!()

    cond do
      follow? and verbose? -> tail_follow_verbose(daemon, id)
      follow? -> tail_follow(daemon, id)
      verbose? -> tail_once_verbose(daemon, id)
      true -> tail_once(daemon, id)
    end
  end

  defp parse_tail_args(args) do
    verbose? = "--verbose" in args
    args = Enum.reject(args, &(&1 == "--verbose"))
    follow? = "--follow" in args or "-f" in args
    args = Enum.reject(args, &(&1 in ["--follow", "-f"]))

    id =
      case args do
        [id] -> id
        _ -> fail("usage: subagent-supervisor tail JOB_ID [--follow|-f] [--verbose]")
      end

    {id, follow?, verbose?}
  end

  defp tail_once(daemon, id) do
    case :rpc.call(daemon, SubagentSupervisor.Registry, :read_stream_output, [id, :parsed]) do
      {:ok, content} ->
        IO.write(content)

      {:error, reason} ->
        fail("error: #{reason}")

      {:badrpc, reason} ->
        fail("rpc failed: #{inspect(reason)}")
    end
  end

  defp tail_once_verbose(daemon, id) do
    case :rpc.call(daemon, SubagentSupervisor.Registry, :read_stream_output, [id, :verbose]) do
      {:ok, content} ->
        IO.write(content)

      {:error, reason} ->
        fail("error: #{reason}")

      {:badrpc, reason} ->
        fail("rpc failed: #{inspect(reason)}")
    end
  end

  defp tail_follow(daemon, id) do
    do_tail_follow(daemon, id, 0)
  end

  defp do_tail_follow(daemon, id, offset) do
    case :rpc.call(daemon, SubagentSupervisor.Registry, :read_output, [id]) do
      {:ok, content} ->
        offset =
          case :rpc.call(daemon, SubagentSupervisor.StreamJSON, :format_incremental, [
                 content,
                 offset
               ]) do
            {:badrpc, _} ->
              len = byte_size(content)

              if len > offset do
                IO.write(binary_part(content, offset, len - offset))
              end

              len

            {tagged_lines, new_offset} when is_list(tagged_lines) ->
              for {text, color} <- tagged_lines, text != "" do
                if color == :red do
                  IO.write([IO.ANSI.red(), text, IO.ANSI.reset()])
                else
                  IO.write(text)
                end
              end

              new_offset
          end

        case :rpc.call(daemon, SubagentSupervisor.Registry, :show, [id]) do
          {:ok, %{status: status}} when status in [:succeeded, :failed] ->
            :ok

          {:ok, _} ->
            Process.sleep(500)
            do_tail_follow(daemon, id, offset)

          {:error, _} ->
            :ok
        end

      {:error, _} ->
        Process.sleep(500)
        do_tail_follow(daemon, id, offset)

      {:badrpc, _} ->
        fail("lost connection to daemon")
    end
  end

  defp tail_follow_verbose(daemon, id) do
    do_tail_follow_verbose(daemon, id, 0)
  end

  defp do_tail_follow_verbose(daemon, id, offset) do
    case :rpc.call(daemon, SubagentSupervisor.Registry, :read_output, [id]) do
      {:ok, content} ->
        len = byte_size(content)

        if len > offset do
          new_bytes = binary_part(content, offset, len - offset)

          new_bytes
          |> String.split("\n", trim: true)
          |> Enum.map(&SubagentSupervisor.StreamJSON.Event.format_verbose/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.each(&IO.puts/1)
        end

        case :rpc.call(daemon, SubagentSupervisor.Registry, :show, [id]) do
          {:ok, %{status: status}} when status in [:succeeded, :failed] ->
            :ok

          {:ok, _} ->
            Process.sleep(500)
            do_tail_follow_verbose(daemon, id, len)

          {:error, _} ->
            :ok
        end

      {:error, _} ->
        Process.sleep(500)
        do_tail_follow_verbose(daemon, id, offset)

      {:badrpc, _} ->
        fail("lost connection to daemon")
    end
  end

  defp top do
    daemon = ensure_daemon!()
    ensure_termbox_nif!()
    normalize_top_terminal_env!()
    Application.ensure_all_started(:ratatouille)
    run_top!(daemon)
  end

  defp run_top!(daemon) do
    old_trap_exit = Process.flag(:trap_exit, true)
    old_logger_level = Logger.level()
    Logger.configure(level: :error)
    Application.put_env(:subagent_supervisor, :top_daemon, daemon)

    try do
      case Ratatouille.Runtime.Supervisor.start_link(runtime: [app: SubagentSupervisor.Top]) do
        {:ok, pid} ->
          ref = Process.monitor(pid)

          receive do
            {:DOWN, ^ref, _, _, _} -> :ok
            {:EXIT, ^pid, _reason} -> :ok
          end

        {:error, {:shutdown, {:failed_to_start_child, Ratatouille.Window, reason}}} ->
          fail_top_window(reason)

        {:error, reason} ->
          fail("failed to start top: #{inspect(reason)}")
      end
    after
      Logger.configure(level: old_logger_level)
      Process.flag(:trap_exit, old_trap_exit)
    end
  end

  defp ensure_termbox_nif! do
    if termbox_nif_available?() do
      :ok
    else
      load_source_checkout_termbox!()
    end
  end

  defp load_source_checkout_termbox! do
    root = escript_dir()
    mix_exs = Path.join(root, "mix.exs")
    ebin = Path.join([root, "_build", "dev", "lib", "ex_termbox", "ebin"])
    nif = Path.join([root, "_build", "dev", "lib", "ex_termbox", "priv", "termbox_bindings.so"])

    unless File.regular?(mix_exs) and File.dir?(ebin) and File.regular?(nif) do
      fail("""
      top requires a release package or a source-checkout escript.

      This executable cannot load ex_termbox's native NIF from inside an escript archive.
      Expected source-checkout files:
        #{mix_exs}
        #{ebin}
        #{nif}
      """)
    end

    Application.unload(:ex_termbox)
    :code.add_patha(String.to_charlist(ebin))

    unless termbox_nif_available?() do
      fail("failed to resolve ex_termbox NIF from #{nif}")
    end
  end

  defp termbox_nif_available? do
    case :code.priv_dir(:ex_termbox) do
      path when is_list(path) ->
        path
        |> to_string()
        |> Path.join("termbox_bindings.so")
        |> File.regular?()

      _ ->
        false
    end
  end

  @doc false
  def normalize_top_terminal_env! do
    term = System.get_env("TERM")

    cond do
      term in [nil, "", "dumb"] ->
        force_xterm_compatible!()

      String.contains?(term, "ghostty") ->
        force_xterm_compatible!()

      String.contains?(term, "tmux") ->
        force_xterm_compatible!()

      Enum.any?(@termbox_compatible_terms, &String.contains?(term, &1)) ->
        clear_ghostty_terminfo!()

      true ->
        force_xterm_compatible!()
    end
  end

  defp force_xterm_compatible! do
    System.put_env("TERM", "xterm-256color")
    clear_ghostty_terminfo!()
  end

  defp clear_ghostty_terminfo! do
    case System.get_env("TERMINFO") do
      nil -> :ok
      path -> if String.contains?(path, "Ghostty.app"), do: System.put_env("TERMINFO", "")
    end
  end

  defp fail_top_window({{:badmatch, {:error, -1}}, _stack}) do
    fail("""
    failed to start top: unsupported terminal #{inspect(System.get_env("TERM"))}

    Try running with a termbox-compatible TERM, for example:
      TERM=xterm-256color TERMINFO= subagent-supervisor top
    """)
  end

  defp fail_top_window({{:badmatch, {:error, -2}}, _stack}) do
    fail("failed to start top: could not open a TTY")
  end

  defp fail_top_window(reason), do: exit(reason)

  defp rpc!(module, function, args) do
    daemon = ensure_daemon!()

    case :rpc.call(daemon, module, function, args) do
      {:badrpc, reason} -> fail("rpc failed: #{inspect(reason)}")
      result -> result
    end
  end

  defp ensure_daemon! do
    start_node!(unique_cli_name())
    daemon = daemon_name()

    case Node.connect(daemon) do
      true ->
        daemon

      false ->
        spawn_daemon!()

        await_daemon!(daemon, 40)
    end
  end

  defp spawn_daemon! do
    System.cmd("epmd", ["-daemon"], stderr_to_stdout: true)

    bin = resolve_self_binary()
    max_concurrency = Application.get_env(:subagent_supervisor, :max_concurrency, 2)
    log_path = Path.join([System.tmp_dir!(), "subagent_supervisor", "daemon.log"])
    File.mkdir_p!(Path.dirname(log_path))

    Port.open(
      {:spawn_executable, System.find_executable("bash")},
      [
        :binary,
        :use_stdio,
        {:args,
         [
           "-c",
           "(#{shell_quote(bin)} server --max-concurrency #{max_concurrency} </dev/null >> #{shell_quote(log_path)} 2>&1) &"
         ]}
      ]
    )
  end

  defp resolve_self_binary do
    case System.fetch_env("SUBAGENT_SUPERVISOR_BIN") do
      {:ok, path} ->
        path

      :error ->
        case :escript.script_name() do
          ~c"" ->
            fail("cannot auto-start daemon: set SUBAGENT_SUPERVISOR_BIN or install the release")

          name ->
            name |> to_string() |> Path.expand()
        end
    end
  end

  defp await_daemon!(daemon, attempts) when attempts > 0 do
    Process.sleep(100)

    case Node.connect(daemon) do
      true -> daemon
      false -> await_daemon!(daemon, attempts - 1)
    end
  end

  defp await_daemon!(daemon, 0) do
    fail("daemon #{daemon} did not start after 4 seconds")
  end

  defp print_result({:ok, value}) do
    IO.puts(SubagentSupervisor.JSON.encode(value))
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
    :"subagent_supervisor@#{short_hostname()}"
  end

  defp unique_cli_name do
    suffix =
      [System.pid(), random_token(4)]
      |> Enum.join("_")
      |> String.replace(~r/[^A-Za-z0-9_]/, "_")

    :"subagent_supervisor_cli_#{suffix}"
  end

  defp short_hostname do
    {:ok, hostname} = :inet.gethostname()
    hostname |> to_string() |> String.split(".") |> hd()
  end

  defp split_command(args) do
    case Enum.split_while(args, &(&1 != "--")) do
      {_flags, []} -> fail("missing command separator `--`")
      {flags, [_separator | command]} when command != [] -> {flags, command}
      {_flags, _} -> fail("missing prompt after `--`")
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
    subagent-supervisor server [--max-concurrency 2]
    subagent-supervisor stop
    subagent-supervisor session [--prefix PREFIX]
    subagent-supervisor agents [--cwd DIR]
    subagent-supervisor start --owner OWNER|--session SESSION [--label LABEL] [--agent NAME] [--cwd DIR] -- PROMPT
    subagent-supervisor wait --owner OWNER|--session SESSION [--ids ID,ID] [--mode any|all] [--timeout SECONDS]
    subagent-supervisor list [--owner OWNER|--session SESSION]
    subagent-supervisor show JOB_ID [--full]
    subagent-supervisor status JOB_ID [--summarize]
    subagent-supervisor tail JOB_ID [--follow|-f] [--verbose]
    subagent-supervisor top
    """)
  end

  defp escript_dir do
    :escript.script_name() |> to_string() |> Path.expand() |> Path.dirname()
  end

  defp fail(message) do
    IO.puts(:stderr, message)
    System.halt(1)
  end
end
