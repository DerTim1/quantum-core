defmodule Quantum.JobBroadcaster do
  @moduledoc """
  This Module is here to broadcast added / removed tabs into the execution pipeline.
  """

  use GenStage

  require Logger

  alias Quantum.{Job, Util}

  @doc """
  Start Job Broadcaster

  ### Arguments

   * `name` - Name of the GenStage
   * `jobs` - Array of `Quantum.Job`

  """
  @spec start_link(GenServer.server(), [Job.t()], boolean()) :: GenServer.on_start()
  def start_link(name, jobs, debug_logging) do
    __MODULE__
    |> GenStage.start_link({jobs, debug_logging}, name: name)
    |> Util.start_or_link()
  end

  @doc false
  @spec child_spec({GenServer.server(), [Job.t()], boolean()}) :: Supervisor.child_spec()
  def child_spec({name, jobs, debug_logging}) do
    %{super([]) | start: {__MODULE__, :start_link, [name, jobs, debug_logging]}}
  end

  @doc false
  def init({jobs, debug_logging}) do
    state = %{
      jobs: Enum.into(jobs, %{}, fn %{name: name} = job -> {name, job} end),
      buffer: for(%{state: :active} = job <- jobs, do: {:add, job}),
      debug_logging: debug_logging
    }

    {:producer, state}
  end

  def handle_demand(demand, %{buffer: buffer} = state) do
    {to_send, remaining} = Enum.split(buffer, demand)

    {:noreply, to_send, %{state | buffer: remaining}}
  end

  def handle_cast(
        {:add, %Job{state: :active, name: job_name} = job},
        %{jobs: jobs, debug_logging: debug_logging} = state
      ) do
    debug_logging &&
      Logger.debug(fn ->
        "[#{inspect(Node.self())}][#{__MODULE__}] Adding job #{inspect(job_name)}"
      end)

    {:noreply, [{:add, job}], %{state | jobs: Map.put(jobs, job_name, job)}}
  end

  def handle_cast(
        {:add, %Job{state: :inactive, name: job_name} = job},
        %{jobs: jobs, debug_logging: debug_logging} = state
      ) do
    debug_logging &&
      Logger.debug(fn ->
        "[#{inspect(Node.self())}][#{__MODULE__}] Adding job #{inspect(job_name)}"
      end)

    {:noreply, [], %{state | jobs: Map.put(jobs, job_name, job)}}
  end

  def handle_cast({:delete, name}, %{jobs: jobs, debug_logging: debug_logging} = state) do
    debug_logging &&
      Logger.debug(fn ->
        "[#{inspect(Node.self())}][#{__MODULE__}] Deleting job #{inspect(name)}"
      end)

    case Map.fetch(jobs, name) do
      {:ok, %{state: :active}} ->
        {:noreply, [{:remove, name}], %{state | jobs: Map.delete(jobs, name)}}

      {:ok, %{state: :inactive}} ->
        {:noreply, [], %{state | jobs: Map.delete(jobs, name)}}

      :error ->
        {:noreply, [], state}
    end
  end

  def handle_cast(
        {:change_state, name, new_state},
        %{jobs: jobs, debug_logging: debug_logging} = state
      ) do
    debug_logging &&
      Logger.debug(fn ->
        "[#{inspect(Node.self())}][#{__MODULE__}] Change job state #{inspect(name)}"
      end)

    case Map.fetch(jobs, name) do
      :error ->
        {:noreply, [], state}

      {:ok, %{state: ^new_state}} ->
        {:noreply, [], state}

      {:ok, job} ->
        jobs = Map.update!(jobs, name, &Job.set_state(&1, new_state))

        case new_state do
          :active ->
            {:noreply, [{:add, %{job | state: new_state}}], %{state | jobs: jobs}}

          :inactive ->
            {:noreply, [{:remove, name}], %{state | jobs: jobs}}
        end
    end
  end

  def handle_cast(:delete_all, %{jobs: jobs, debug_logging: debug_logging} = state) do
    debug_logging &&
      Logger.debug(fn ->
        "[#{inspect(Node.self())}][#{__MODULE__}] Deleting all jobs"
      end)

    messages = for {name, %Job{state: :active}} <- jobs, do: {:remove, name}

    {:noreply, messages, %{state | jobs: %{}}}
  end

  def handle_call(:jobs, _, %{jobs: jobs} = state), do: {:reply, Map.to_list(jobs), [], state}

  def handle_call({:find_job, name}, _, %{jobs: jobs} = state),
    do: {:reply, Map.get(jobs, name), [], state}
end
