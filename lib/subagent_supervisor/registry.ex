defmodule SubagentSupervisor.Registry do
  @moduledoc """
  Owns job state and supervises bash subprocess tasks.
  """

  use GenServer

  alias SubagentSupervisor.Job
  alias SubagentSupervisor.StreamJSON

  @type wait_mode :: :any | :all

  @doc """
  Starts the Registry GenServer as a named process.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc """
  Registers and runs a bash subprocess job.

  Required attributes: `"owner"`, `"command"`.
  Optional attributes: `"cwd"`, `"label"`, `"id"`.

  Returns `{:ok, job_map}` on success or raises `ArgumentError` if required
  attributes are missing.
  """
  @spec start_job(map()) :: {:ok, map()} | no_return()
  def start_job(attrs) when is_map(attrs) do
    GenServer.call(__MODULE__, {:start_job, attrs})
  end

  @doc """
  Lists jobs, optionally filtered by owner.

  Pass `nil` (the default) to return all jobs.
  """
  @spec list(String.t() | nil) :: {:ok, [map()]}
  def list(owner \\ nil) do
    GenServer.call(__MODULE__, {:list, owner})
  end

  @doc """
  Returns the details of a single job.

  By default, output is omitted. Pass `include_output: true` to include
  the full captured output, or `include_output: :digest` to include a
  truncated digest.

  Returns `{:error, :not_found}` when the id does not exist.
  """
  @spec show(String.t(), keyword()) :: {:ok, map()} | {:error, :not_found}
  def show(id, opts \\ []) do
    GenServer.call(__MODULE__, {:show, id, opts})
  end

  @doc """
  Returns a lightweight status digest for a job: metadata plus a
  truncated view of the output.

  Returns `{:error, :not_found}` when the id does not exist.
  """
  @spec status(String.t()) :: {:ok, map()} | {:error, :not_found}
  def status(id) do
    GenServer.call(__MODULE__, {:status, id})
  end

  @doc """
  Returns dashboard state: jobs grouped by owner, concurrency stats,
  supervision tree children, and daemon start time.
  """
  @spec dashboard_state() :: {:ok, map()}
  def dashboard_state do
    GenServer.call(__MODULE__, :dashboard_state)
  end

  @doc """
  Resets all job state. Intended for use in tests.
  """
  @spec reset_for_test(pos_integer()) :: :ok
  def reset_for_test(max_concurrency \\ max_concurrency()) do
    GenServer.call(__MODULE__, {:reset_for_test, max_concurrency})
  end

  @doc """
  Reads the current output for a job from its temp file.

  Returns `{:ok, content}` with partial or full output, or
  `{:error, :not_found}` / `{:error, :no_output}`.
  """
  @spec read_output(String.t()) :: {:ok, String.t()} | {:error, :not_found | :no_output}
  def read_output(id) do
    GenServer.call(__MODULE__, {:read_output, id})
  end

  @doc """
  Reads the stream-json capture for a job, formatting it according to `mode`.

  Modes:
    * `:parsed`  — text deltas + tool labels (default, concise)
    * `:verbose` — assembled snapshots with thinking, tool I/O, cost metadata

  Returns `{:ok, text}`, `{:error, :not_found}`, or `{:error, :no_output}`.
  """
  @spec read_stream_output(String.t(), :parsed | :verbose) ::
          {:ok, String.t()} | {:error, :not_found | :no_output}
  def read_stream_output(id, mode \\ :parsed) do
    GenServer.call(__MODULE__, {:read_stream_output, id, mode})
  end

  @doc """
  Blocks until the selected wake rule is satisfied.

  * `:any` — returns when at least one matching job finishes.
  * `:all` — returns when every matching job finishes.

  Times out after `timeout_ms` milliseconds, returning `{:error, :timeout}`.
  """
  @spec wait(String.t() | nil, [String.t()], wait_mode(), pos_integer()) ::
          {:ok, [map()]} | {:error, :timeout}
  def wait(owner, ids, mode, timeout_ms) when mode in [:any, :all] do
    GenServer.call(__MODULE__, {:wait, owner, ids, mode, timeout_ms}, timeout_ms + 1_000)
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  @impl true
  def init(_opts) do
    output_dir = Path.join(System.tmp_dir!(), "subagent_supervisor")
    File.mkdir_p!(output_dir)

    {:ok,
     %{
       jobs: %{},
       refs: %{},
       waiters: [],
       max_concurrency: max_concurrency(),
       started_at: DateTime.utc_now(),
       output_dir: output_dir,
       allowed_launchers: resolve_allowed_launchers()
     }}
  end

  @impl true
  def handle_call({:start_job, attrs}, _from, state) do
    owner = required!(attrs, "owner")
    command = required!(attrs, "command")
    validate_command!(command, state.allowed_launchers)
    cwd = Map.get(attrs, "cwd", File.cwd!())
    label = Map.get(attrs, "label")
    id = Map.get(attrs, "id", new_id())
    inserted_at = now()

    job = %Job{
      id: id,
      owner: owner,
      command: command,
      cwd: cwd,
      label: label,
      status: :queued,
      inserted_at: inserted_at,
      started_at: nil
    }

    state = state |> put_job(job) |> start_available_jobs()
    {:reply, {:ok, public_job(Map.fetch!(state.jobs, id))}, state}
  end

  def handle_call({:list, owner}, _from, state) do
    jobs =
      state.jobs
      |> Map.values()
      |> Enum.filter(&(is_nil(owner) or &1.owner == owner))
      |> sort_jobs()
      |> Enum.map(&public_job/1)

    {:reply, {:ok, jobs}, state}
  end

  def handle_call({:show, id, opts}, _from, state) do
    reply =
      case Map.fetch(state.jobs, id) do
        {:ok, job} ->
          include_output =
            case Keyword.get(opts, :include_output) do
              true -> true
              :digest -> :digest
              _ -> false
            end

          {:ok, public_job(job, include_output: include_output)}

        :error ->
          {:error, :not_found}
      end

    {:reply, reply, state}
  end

  def handle_call({:status, id}, _from, state) do
    reply =
      case Map.fetch(state.jobs, id) do
        {:ok, job} -> {:ok, build_status(job, state)}
        :error -> {:error, :not_found}
      end

    {:reply, reply, state}
  end

  def handle_call({:reset_for_test, max_concurrency}, _from, state) do
    Enum.each(state.waiters, fn waiter ->
      Process.cancel_timer(waiter.timer)
      GenServer.reply(waiter.from, {:error, :reset})
    end)

    File.rm_rf(state.output_dir)
    File.mkdir_p!(state.output_dir)

    {:reply, :ok,
     %{state | jobs: %{}, refs: %{}, waiters: [], max_concurrency: max(max_concurrency, 1)}}
  end

  def handle_call(:dashboard_state, _from, state) do
    jobs = state.jobs |> Map.values() |> Enum.map(&public_job/1)

    grouped =
      jobs
      |> Enum.group_by(& &1.owner)
      |> Enum.map(fn {owner, owner_jobs} -> %{owner: owner, jobs: owner_jobs} end)
      |> Enum.sort_by(& &1.owner)

    running = Enum.count(jobs, &(&1.status == :running))
    queued = Enum.count(jobs, &(&1.status == :queued))

    {:ok, sup_children} =
      case Supervisor.which_children(SubagentSupervisor.Supervisor) do
        children -> {:ok, format_sup_children(children)}
      end

    result = %{
      jobs_by_owner: grouped,
      total_jobs: length(jobs),
      running: running,
      queued: queued,
      max_concurrency: state.max_concurrency,
      started_at: state.started_at,
      supervision_tree: [
        %{
          name: "SubagentSupervisor.Supervisor",
          type: :supervisor,
          children: sup_children
        }
      ]
    }

    {:reply, {:ok, result}, state}
  end

  def handle_call({:wait, owner, ids, mode, timeout_ms}, from, state) do
    selector = normalize_selector(owner, ids)

    case wait_result(state.jobs, selector, mode) do
      {:ready, jobs} ->
        {:reply, {:ok, Enum.map(jobs, &public_job(&1, include_output: true))}, state}

      :pending ->
        ref = make_ref()
        timer = Process.send_after(self(), {:wait_timeout, ref}, timeout_ms)
        waiter = %{ref: ref, timer: timer, from: from, selector: selector, mode: mode}
        {:noreply, %{state | waiters: [waiter | state.waiters]}}
    end
  end

  def handle_call({:read_output, id}, _from, state) do
    reply =
      case Map.fetch(state.jobs, id) do
        {:ok, %Job{output_path: nil}} ->
          {:error, :no_output}

        {:ok, %Job{output_path: path}} ->
          if File.exists?(path) do
            {:ok, File.read!(path)}
          else
            {:error, :no_output}
          end

        :error ->
          {:error, :not_found}
      end

    {:reply, reply, state}
  end

  def handle_call({:read_stream_output, id, mode}, _from, state) do
    reply =
      case Map.fetch(state.jobs, id) do
        {:ok, %Job{output_path: nil}} ->
          {:error, :no_output}

        {:ok, %Job{output_path: path}} ->
          if File.exists?(path) do
            raw = File.read!(path)

            text =
              case mode do
                :verbose -> StreamJSON.extract_verbose(raw)
                _ -> raw |> StreamJSON.format_incremental(0) |> elem(0) |> tagged_text()
              end

            {:ok, text}
          else
            {:error, :no_output}
          end

        :error ->
          {:error, :not_found}
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_info({ref, {id, started_at, finished_at, exit_status}}, state) do
    Process.demonitor(ref, [:flush])

    state =
      update_job(state, id, fn job ->
        raw =
          if job.output_path && File.exists?(job.output_path) do
            File.read!(job.output_path)
          else
            ""
          end

        output = StreamJSON.extract_text(raw)

        %{
          job
          | status: terminal_status(exit_status),
            exit_status: exit_status,
            output: output,
            started_at: started_at,
            finished_at: finished_at,
            task_ref: nil
        }
      end)

    state = state |> start_available_jobs() |> reply_ready_waiters()
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    id = Map.get(state.refs, ref)

    state =
      if id do
        update_job(state, id, fn job ->
          raw =
            if job.output_path && File.exists?(job.output_path) do
              File.read!(job.output_path)
            else
              ""
            end

          parsed = StreamJSON.extract_text(raw)
          partial = if raw != parsed, do: "\n" <> parsed, else: parsed

          %{
            job
            | status: :failed,
              exit_status: nil,
              output: "Task process exited before returning: #{inspect(reason)}" <> partial,
              finished_at: now(),
              task_ref: nil
          }
        end)
      else
        state
      end

    state = state |> start_available_jobs() |> reply_ready_waiters()
    {:noreply, state}
  end

  def handle_info({:wait_timeout, ref}, state) do
    {expired, pending} = Enum.split_with(state.waiters, &(&1.ref == ref))

    Enum.each(expired, fn waiter ->
      GenServer.reply(waiter.from, {:error, :timeout})
    end)

    {:noreply, %{state | waiters: pending}}
  end

  defp put_job(state, job) do
    refs = if job.task_ref, do: Map.put(state.refs, job.task_ref, job.id), else: state.refs
    %{state | jobs: Map.put(state.jobs, job.id, job), refs: refs}
  end

  defp start_available_jobs(state) do
    available = state.max_concurrency - running_count(state)

    if available <= 0 do
      state
    else
      state.jobs
      |> Map.values()
      |> Enum.filter(&(&1.status == :queued))
      |> sort_jobs()
      |> Enum.take(available)
      |> Enum.reduce(state, fn job, acc ->
        update_job(acc, job.id, &start_job_task(&1, state.output_dir))
      end)
    end
  end

  defp start_job_task(job, output_dir) do
    started_at = now()
    output_path = Path.join(output_dir, "#{job.id}.log")
    File.write!(output_path, "")
    command = job.command

    task =
      Task.Supervisor.async_nolink(SubagentSupervisor.TaskSupervisor, fn ->
        port =
          Port.open(
            {:spawn_executable, System.find_executable("bash")},
            [
              :binary,
              :use_stdio,
              :exit_status,
              {:args, ["-lc", "(#{command}) < /dev/null 2>&1"]},
              {:cd, String.to_charlist(job.cwd)}
            ]
          )

        exit_status = collect_port_output(port, output_path)
        {job.id, started_at, now(), exit_status}
      end)

    %{
      job
      | status: :running,
        started_at: started_at,
        task_ref: task.ref,
        output_path: output_path
    }
  end

  defp collect_port_output(port, path) do
    receive do
      {^port, {:data, data}} ->
        File.write!(path, data, [:append])
        collect_port_output(port, path)

      {^port, {:exit_status, code}} ->
        receive do
          {^port, :closed} -> :ok
        after
          100 -> :ok
        end

        code
    end
  end

  defp running_count(state) do
    state.jobs
    |> Map.values()
    |> Enum.count(&(&1.status == :running))
  end

  defp update_job(state, id, fun) do
    case Map.fetch(state.jobs, id) do
      {:ok, job} ->
        updated = fun.(job)
        refs = if job.task_ref, do: Map.delete(state.refs, job.task_ref), else: state.refs
        refs = if updated.task_ref, do: Map.put(refs, updated.task_ref, id), else: refs
        %{state | jobs: Map.put(state.jobs, id, updated), refs: refs}

      :error ->
        state
    end
  end

  defp reply_ready_waiters(state) do
    {ready, pending} =
      Enum.split_with(state.waiters, fn waiter ->
        match?({:ready, _jobs}, wait_result(state.jobs, waiter.selector, waiter.mode))
      end)

    Enum.each(ready, fn waiter ->
      {:ready, jobs} = wait_result(state.jobs, waiter.selector, waiter.mode)
      Process.cancel_timer(waiter.timer)
      GenServer.reply(waiter.from, {:ok, Enum.map(jobs, &public_job(&1, include_output: true))})
    end)

    %{state | waiters: pending}
  end

  defp wait_result(jobs, selector, :any) do
    candidates = select_jobs(jobs, selector)

    case Enum.find(candidates, &terminal?/1) do
      nil -> :pending
      job -> {:ready, [job]}
    end
  end

  defp wait_result(jobs, selector, :all) do
    candidates = select_jobs(jobs, selector)

    cond do
      candidates == [] -> :pending
      Enum.all?(candidates, &terminal?/1) -> {:ready, candidates}
      true -> :pending
    end
  end

  defp select_jobs(jobs, %{owner: owner, ids: []}) do
    jobs
    |> Map.values()
    |> Enum.filter(&(&1.owner == owner))
    |> sort_jobs()
  end

  defp select_jobs(jobs, %{ids: ids}) do
    ids
    |> Enum.map(&Map.get(jobs, &1))
    |> Enum.reject(&is_nil/1)
    |> sort_jobs()
  end

  defp normalize_selector(owner, ids), do: %{owner: owner, ids: ids || []}
  defp terminal?(%Job{status: status}), do: status in [:succeeded, :failed]
  defp terminal_status(0), do: :succeeded
  defp terminal_status(_), do: :failed
  defp sort_jobs(jobs), do: Enum.sort_by(jobs, &DateTime.to_unix(&1.inserted_at, :microsecond))

  defp public_job(job, opts \\ []) do
    base = %{
      id: job.id,
      owner: job.owner,
      label: job.label,
      command: job.command,
      cwd: job.cwd,
      status: job.status,
      exit_status: job.exit_status,
      inserted_at: job.inserted_at,
      started_at: job.started_at,
      finished_at: job.finished_at
    }

    case Keyword.get(opts, :include_output, false) do
      true -> Map.put(base, :output, job.output)
      :digest -> Map.put(base, :output, job.output)
      _ -> base
    end
  end

  defp build_status(job, _state) do
    raw_output = read_job_output(job)

    output_digest =
      case raw_output do
        nil ->
          nil

        "" ->
          ""

        raw ->
          text = StreamJSON.extract_text(raw)
          truncate_text(text)
      end

    %{
      id: job.id,
      label: job.label,
      status: job.status,
      owner: job.owner,
      started_at: job.started_at,
      finished_at: job.finished_at,
      output_digest: output_digest
    }
  end

  defp read_job_output(%Job{output_path: nil}), do: nil

  defp read_job_output(%Job{output_path: path}) do
    if File.exists?(path), do: File.read!(path), else: nil
  end

  @max_digest 4000
  @head_chars 500
  @tail_chars 3000

  defp truncate_text(text) when byte_size(text) <= @max_digest, do: text

  defp truncate_text(text) do
    head = String.slice(text, 0, @head_chars)
    tail = String.slice(text, String.length(text) - @tail_chars, @tail_chars)
    head <> "\n\n... [truncated] ...\n\n" <> tail
  end

  defp tagged_text(chunks) do
    chunks
    |> Enum.map(fn {text, _color} -> text end)
    |> Enum.join()
  end

  defp required!(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} when value not in [nil, ""] -> value
      _ -> raise ArgumentError, "missing required #{key}"
    end
  end

  defp new_id do
    "job_" <> (:crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false))
  end

  defp now, do: DateTime.utc_now()

  defp max_concurrency do
    :subagent_supervisor
    |> Application.get_env(:max_concurrency, 2)
    |> max(1)
  end

  defp format_sup_children(children) do
    Enum.map(children, fn {id, pid, type, _modules} ->
      %{
        name: inspect(id),
        type: type,
        pid: format_pid(pid),
        children: child_grandchildren(id, pid)
      }
    end)
  end

  defp child_grandchildren(:subagent_supervisor_task_supervisor, pid) when is_pid(pid) do
    case Task.Supervisor.children(pid) do
      pids ->
        Enum.map(
          pids,
          &%{name: "Task #{format_pid(&1)}", type: :worker, pid: format_pid(&1), children: []}
        )
    end
  end

  defp child_grandchildren(_id, _pid), do: []

  defp format_pid(nil), do: "not started"
  defp format_pid(:restarting), do: "restarting"
  defp format_pid(pid) when is_pid(pid), do: inspect(pid)

  defp resolve_allowed_launchers do
    SubagentSupervisor.Launcher.allowed_launchers()
  end

  defp validate_command!(command, allowed_launchers) do
    unless Enum.any?(allowed_launchers, fn launcher ->
             command == launcher or
               String.starts_with?(command, launcher <> " ") or
               command == shell_quote_launcher(launcher) or
               String.starts_with?(command, shell_quote_launcher(launcher) <> " ")
           end) do
      raise ArgumentError,
            "command rejected: must use an allowed launcher (#{inspect(allowed_launchers)}), got: #{command}"
    end
  end

  defp shell_quote_launcher(launcher) do
    if String.match?(launcher, ~r/^[A-Za-z0-9_\/.,:=@%+-]+$/) do
      launcher
    else
      "'" <> String.replace(launcher, "'", "'\"'\"'") <> "'"
    end
  end
end
