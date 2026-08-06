defmodule Arrea.BulkheadPropertyTest do
  use ExUnit.Case
  use ExUnitProperties

  import StreamData

  alias Arrea.Bulkhead

  @test_id :bulkhead_property
  @count_test_id :bulkhead_property_count

  setup do
    _ = start_supervised({Registry, keys: :unique, name: Arrea.Bulkhead.Registry})

    for {test_id, max} <- [{@test_id, 2}, {@count_test_id, 1}] do
      case Registry.lookup(Arrea.Bulkhead.Registry, test_id) do
        [{existing_pid, _}] ->
          Process.exit(existing_pid, :kill)
          :timer.sleep(10)

        [] ->
          :ok
      end

      {:ok, _} = Bulkhead.start_link(test_id, max)
    end

    :ok
  end

  property "active calls never exceed max_concurrent" do
    check all max <- integer(1..4),
              durations <- list_of(integer(1..15), min_length: 1, max_length: 30) do
      reset_bulkhead(@test_id, max)
      parent = self()

      # Each caller holds its slot for `duration` ms. We track the peak
      # number of concurrently running functions with an agent.
      {:ok, tracker} = Agent.start_link(fn -> %{active: 0, peak: 0} end)
      on_exit(fn -> Process.exit(tracker, :kill) end)

      tasks =
        Enum.map(durations, fn duration ->
          Task.async(fn ->
            case Bulkhead.run(@test_id, fn ->
                   Agent.update(tracker, fn %{active: a, peak: p} ->
                     %{active: a + 1, peak: max(p, a + 1)}
                   end)

                   Process.sleep(duration)

                   Agent.update(tracker, fn %{active: a} = acc -> %{acc | active: a - 1} end)
                   :done
                 end) do
              {:ok, :done} -> :accepted
              {:error, :bulkhead_full} -> :rejected
            end
          end)
        end)

      results = Task.await_many(tasks, 10_000)
      peak = Agent.get(tracker, & &1.peak)

      assert peak <= max,
             "peak concurrency #{peak} exceeded max_concurrent #{max}"

      # Slots were all released: availability is back to max_concurrent.
      assert Bulkhead.available(@test_id) == max
      _ = parent
    end
  end

  property "results are consistent: accepted + rejected == number of calls" do
    check all max <- integer(1..3),
              durations <- list_of(integer(1..5), min_length: 1, max_length: 15) do
      reset_bulkhead(@count_test_id, max)

      tasks =
        Enum.map(durations, fn duration ->
          Task.async(fn ->
            case Bulkhead.run(@count_test_id, fn ->
                   Process.sleep(duration)
                   :done
                 end) do
              {:ok, :done} -> :accepted
              {:error, :bulkhead_full} -> :rejected
            end
          end)
        end)

      results = Task.await_many(tasks, 10_000)

      assert length(results) == length(durations)
      assert Enum.all?(results, &(&1 in [:accepted, :rejected]))

      status = Bulkhead.status(@count_test_id)
      assert status.accepted == Enum.count(results, &(&1 == :accepted))
      assert status.rejected == Enum.count(results, &(&1 == :rejected))
    end
  end

  defp reset_bulkhead(test_id, max) do
    :sys.replace_state(Registry.lookup(Arrea.Bulkhead.Registry, test_id) |> hd() |> elem(0), fn _ ->
      %{
        name: test_id,
        max_concurrent: max,
        active: 0,
        accepted: 0,
        rejected: 0
      }
    end)
  end
end
