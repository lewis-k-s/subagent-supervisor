defmodule CodexSubagents.Registry do
  @moduledoc """
  Owns job state and supervises bash subprocess tasks.
  """

  use GenServer

  alias CodexSubagents.Job

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
  Returns the full details of a single job including captured output.

  Returns `{:error, :not_found}` when the id does not exist.
  """
  @spec show(String.t()) :: {:ok, map()} | {:error, :not_found}
  def show(id) do
    GenServer.call(__MODULE__, {:show, id})
  end

  @doc """
  Resets all job state. Intended for use in tests.
  """
  @spec reset_for_test(pos_integer()) :: :ok
  def reset_for_test(max_concurrency \\ max_concurrency()) do
    GenServer.call(__MODULE__, {:reset_for_test, max_concurrency})
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
    {:ok, %{jobs: %{}, refs: %{}, waiters: [], max_concurrency: max_concurrency()}}
  end

  @impl true
  def handle_call({:start_job, attrs}, _from, state) do
    owner = required!(attrs, "owner")
    command = required!(attrs, "command")
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

  def handle_call({:show, id}, _from, state) do
    reply =
      case Map.fetch(state.jobs, id) do
        {:ok, job} -> {:ok, public_job(job, include_output: true)}
        :error -> {:error, :not_found}
      end

    {:reply, reply, state}
  end

  def handle_call({:reset_for_test, max_concurrency}, _from, state) do
    Enum.each(state.waiters, fn waiter ->
      Process.cancel_timer(waiter.timer)
      GenServer.reply(waiter.from, {:error, :reset})
    end)

    {:reply, :ok,
     %{state | jobs: %{}, refs: %{}, waiters: [], max_concurrency: max(max_concurrency, 1)}}
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

  @impl true
  def handle_info({ref, {id, started_at, finished_at, exit_status, output}}, state) do
    Process.demonitor(ref, [:flush])

    state =
      update_job(state, id, fn job ->
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
          %{
            job
            | status: :failed,
              exit_status: nil,
              output: "Task process exited before returning: #{inspect(reason)}",
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
      |> Enum.reduce(state, fn job, acc -> update_job(acc, job.id, &start_job_task/1) end)
    end
  end

  defp start_job_task(job) do
    started_at = now()

    task =
      Task.Supervisor.async_nolink(CodexSubagents.TaskSupervisor, fn ->
        {output, exit_status} =
          System.cmd("bash", ["-lc", job.command], cd: job.cwd, stderr_to_stdout: true)

        {job.id, started_at, now(), exit_status, output}
      end)

    %{job | status: :running, started_at: started_at, task_ref: task.ref}
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

    if Keyword.get(opts, :include_output, false),
      do: Map.put(base, :output, job.output),
      else: base
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
    :codex_subagents
    |> Application.get_env(:max_concurrency, 2)
    |> max(1)
  end
end
