defmodule Explorer.Chain.Import.Stage do
  @moduledoc """
  Behaviour used to chunk `changes_list` into multiple `t:Ecto.Multi.t/0`` that can run in separate transactions to
  limit the time that transactions take and how long blocking locks are held in Postgres.
  """

  alias Ecto.Multi
  alias Explorer.Chain.Import.Runner

  @typedoc """
  Maps `t:Explorer.Chain.Import.Runner.t/0` callback module to the `t:Explorer.Chain.Import.Runner.changes_list/0` it
  can import.
  """
  @type runner_to_changes_list :: %{Runner.t() => Runner.changes_list()}

  @doc """
  The configured runners consumed by this stage in `c:multis/0`.
  The list should be in the order that the runners are executed and depends on chain type.
  """
  @callback runners() :: [Runner.t(), ...]

  @doc """
  Returns a list of all possible runners provided by the module.
  This list is intended to include all runners, irrespective of chain type or
  other configuration options.
  """
  @callback all_runners() :: [Runner.t(), ...]

  @doc """
  Chunks `changes_list` into 1 or more `t:Ecto.Multi.t/0` that can be run in separate transactions.

  The runners used by the stage should be removed from the returned `runner_to_changes_list` map.
  """
  @callback multis(runner_to_changes_list, %{optional(atom()) => term()}) :: {[Multi.t()], runner_to_changes_list}

  @doc """
  Uses a single `t:Explorer.Chain.Runner.t/0` and chunks the `changes_list` across multiple `t:Ecto.Multi.t/0`
  """
  @spec chunk_every(runner_to_changes_list, Runner.t(), chunk_size :: pos_integer(), %{optional(atom()) => term()}) ::
          {[Multi.t()], runner_to_changes_list}
  def chunk_every(runner_to_changes_list, runner, chunk_size, options)
      when is_map(runner_to_changes_list) and is_atom(runner) and is_integer(chunk_size) and is_map(options) do
    {changes_list, unstaged_runner_to_changes_list} = Map.pop(runner_to_changes_list, runner)
    multis = changes_list_chunk_every(changes_list, chunk_size, runner, options)

    {multis, unstaged_runner_to_changes_list}
  end

  defp changes_list_chunk_every(nil, _, _, _), do: []

  defp changes_list_chunk_every(changes_list, chunk_size, runner, options) do
    changes_list
    |> Stream.chunk_every(chunk_size)
    |> Enum.map(fn changes_chunk ->
      Task.async(fn ->
        runner.run(Multi.new(), changes_chunk, options)
      end)
    end)
    |> Task.yield_many(:timer.seconds(60))
    |> Enum.map(fn {_task, res} ->
      case res do
        {:ok, result} ->
          result

        {:exit, reason} ->
          raise "Addresses insert/update terminated: #{inspect(reason)}"

        nil ->
          raise "Addresses insert/update timed out."
      end
    end)
  end

  @spec single_multi([Runner.t()], runner_to_changes_list, %{optional(atom()) => term()}) ::
          {Multi.t(), runner_to_changes_list}
  def single_multi(runners, runner_to_changes_list, options) do
    runners
    |> Enum.reduce({Multi.new(), runner_to_changes_list}, fn runner, {multi, remaining_runner_to_changes_list} ->
      {changes_list, new_remaining_runner_to_changes_list} = Map.pop(remaining_runner_to_changes_list, runner)

      new_multi =
        case changes_list do
          nil ->
            multi

          _ ->
            runner.run(multi, changes_list, options)
        end

      {new_multi, new_remaining_runner_to_changes_list}
    end)
  end

  @spec concurrent_multis([Runner.t()], runner_to_changes_list, %{optional(atom()) => term()}) ::
          {[Multi.t()], runner_to_changes_list}
  def concurrent_multis(runners, runner_to_changes_list, options) do
    # IO.inspect("Gimme runner_to_changes_list #{inspect(runner_to_changes_list)}")
    # IO.inspect("Gimme runner_to_changes_list keys #{inspect(Map.keys(runner_to_changes_list))}")

    {final_changes_list, final_remaining_runner_to_changes_list} =
      runners
      |> Enum.reduce({[], runner_to_changes_list}, fn runner, {acc, remaining_runner_to_changes_list} ->
        {changes_list, new_remaining_runner_to_changes_list} = Map.pop(remaining_runner_to_changes_list, runner)

        # IO.inspect("Gimme runner #{inspect(runner)}")
        # IO.inspect("Gimme changes_list #{inspect(changes_list)}")

        new_acc =
          case changes_list do
            nil ->
              [{runner, []} | acc]

            _ ->
              [{runner, changes_list} | acc]
          end

        # {new_multi, new_remaining_runner_to_changes_list}
        {new_acc, new_remaining_runner_to_changes_list}
      end)

    # IO.inspect("Gimme final_changes_list #{inspect(final_changes_list)}")

    acc =
      final_changes_list
      |> Enum.map(fn {runner, changes_chunk} ->
        if Enum.count(changes_chunk) > 0 do
          Task.async(fn ->
            runner.run(Multi.new(), changes_chunk, options)
          end)
        else
          nil
        end
      end)
      |> Enum.filter(& &1)
      |> Task.yield_many(:timer.seconds(60))
      |> Enum.reduce([], fn {_task, res}, acc ->
        case res do
          {:ok, result} ->
            [result | acc]
        end
      end)

    # IO.inspect("Gimme result of single_multi_2 #{inspect({acc, final_remaining_runner_to_changes_list})}")

    {acc, final_remaining_runner_to_changes_list}
  end
end
