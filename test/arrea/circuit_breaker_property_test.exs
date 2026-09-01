defmodule Arrea.CircuitBreakerPropertyTest do
  use ExUnit.Case
  use ExUnitProperties

  import StreamData

  alias Arrea.CircuitBreaker

  @threshold 5
  @timeout_ticks 3
  @required_successes max(1, div(@threshold, 2))

  @test_id :circuit_breaker_property

  @ops [:failure, :success, :call_ok, :call_fail]

  # Reference model: pure state machine replicating the breaker rules.
  defmodule Model do
    defstruct state: :closed,
              failures: 0,
              successes: 0,
              last_failure_tick: nil,
              tick: 0
  end

  setup do
    _ = start_supervised({Registry, keys: :unique, name: Arrea.CircuitBreaker.Registry})

    case Registry.lookup(Arrea.CircuitBreaker.Registry, @test_id) do
      [{existing_pid, _}] ->
        Process.exit(existing_pid, :kill)
        :timer.sleep(10)

      [] ->
        :ok
    end

    {:ok, pid} =
      CircuitBreaker.start_link(
        name: @test_id,
        threshold: @threshold,
        timeout: 100_000
      )

    %{pid: pid}
  end

  property "matches the reference model and never executes while open" do
    check all(ops <- list_of(member_of(@ops), max_length: 40)) do
      pid = breaker_pid()
      reset_breaker(pid)
      model = %Model{}

      Enum.reduce(ops, model, fn op, model ->
        {model, verdict} = step(model, op, pid)
        apply_to_breaker(op, verdict)
        assert_breaker_matches(model, pid)
        model
      end)
    end
  end

  # Applies one op to the model. Returns {next_model, verdict}.
  # `verdict` is :allowed | :blocked for call ops (the model's prediction)
  # or :no_call for failure/success ops.
  defp step(model, op, breaker_pid) do
    tick = model.tick + 1
    model = %{model | tick: tick}

    case model.state do
      :closed ->
        apply_closed(model, op)

      :open ->
        expired = timeout_expired?(model)
        open_probe_setup(expired, op, breaker_pid, model)
        apply_open(model, expired, op)

      :half_open ->
        apply_half_open(model, op)
    end
  end

  # When a call op arrives while the breaker is open, the real breaker
  # either transitions to half-open (probe) or refreshes the failure
  # deadline. Drive the real breaker to match the model's expectation.
  defp open_probe_setup(expired, op, breaker_pid, _model) do
    if op in [:call_ok, :call_fail] do
      if expired,
        do: force_timeout_expired(breaker_pid),
        else: refresh_last_failure(breaker_pid)
    end
  end

  defp apply_closed(model, op) do
    case op do
      :failure -> {fail(model), :no_call}
      :success -> {%{model | successes: model.successes + 1}, :no_call}
      :call_ok -> {%{model | successes: model.successes + 1}, :allowed}
      :call_fail -> {fail(model), :allowed}
    end
  end

  defp apply_open(model, expired, op) do
    case {op, expired} do
      {:failure, _} ->
        {%{model | failures: model.failures + 1, last_failure_tick: model.tick}, :no_call}

      {:success, _} ->
        {%{model | state: :closed, failures: 0, successes: 0}, :no_call}

      {:call_ok, false} ->
        # The real breaker refreshes last_failure_at on every blocked call,
        # pushing the retry deadline forward — mirror that in the model.
        {%{model | last_failure_tick: model.tick}, :blocked}

      {:call_fail, false} ->
        {%{model | last_failure_tick: model.tick}, :blocked}

      {:call_ok, true} ->
        # open → half_open (probe) → success
        maybe_close(%{model | state: :half_open, successes: 1})

      {:call_fail, true} ->
        # open → half_open (probe) → failure → open again
        {%{model | failures: model.failures + 1, last_failure_tick: model.tick}, :allowed}
    end
  end

  defp apply_half_open(model, op) do
    case op do
      :success ->
        maybe_close(%{model | successes: model.successes + 1})

      :failure ->
        {%{
           model
           | state: :open,
             failures: model.failures + 1,
             successes: 0,
             last_failure_tick: model.tick
         }, :no_call}

      :call_ok ->
        maybe_close(%{model | successes: model.successes + 1})

      :call_fail ->
        {%{
           model
           | state: :open,
             failures: model.failures + 1,
             successes: 0,
             last_failure_tick: model.tick
         }, :allowed}
    end
  end

  defp maybe_close(model) do
    if model.successes >= @required_successes do
      {%{model | state: :closed, failures: 0, successes: 0}, :allowed}
    else
      {model, :allowed}
    end
  end

  defp fail(model) do
    failures = model.failures + 1

    if failures >= @threshold do
      %{model | failures: failures, state: :open, last_failure_tick: model.tick}
    else
      %{model | failures: failures}
    end
  end

  defp timeout_expired?(%Model{last_failure_tick: nil}), do: false

  defp timeout_expired?(%Model{last_failure_tick: last, tick: tick}),
    do: tick - last > @timeout_ticks

  # ── Real breaker interaction ────────────────────────────────────────────

  defp force_timeout_expired(breaker_pid) do
    :sys.replace_state(breaker_pid, fn state ->
      %{state | last_failure_at: System.monotonic_time(:millisecond) - 200_000}
    end)
  end

  defp refresh_last_failure(breaker_pid) do
    :sys.replace_state(breaker_pid, fn state ->
      %{state | last_failure_at: System.monotonic_time(:millisecond)}
    end)
  end

  defp apply_to_breaker(op, verdict) do
    case op do
      :failure ->
        CircuitBreaker.failure(@test_id)

      :success ->
        CircuitBreaker.success(@test_id)

      :call_ok ->
        result = CircuitBreaker.call(@test_id, fn -> :ok end)

        case verdict do
          :allowed ->
            assert result == {:ok, :ok}

          :blocked ->
            # Invariant: never executes while open.
            assert result == {:error, :circuit_open},
                   "breaker executed a call while open (verdict=#{inspect(verdict)})"
        end

      :call_fail ->
        result = CircuitBreaker.call(@test_id, fn -> raise "boom" end)

        case verdict do
          :allowed ->
            assert result == {:error, :execution_failed}

          :blocked ->
            assert result == {:error, :circuit_open},
                   "breaker executed a call while open (verdict=#{inspect(verdict)})"
        end
    end

    :ok
  end

  defp assert_breaker_matches(model, breaker_pid) do
    # The synchronous :sys.get_state call also drains any pending casts.
    breaker = :sys.get_state(breaker_pid)

    assert breaker.state == model.state,
           "state mismatch: model=#{model.state} breaker=#{breaker.state}"

    assert breaker.failures == model.failures,
           "failures mismatch: model=#{model.failures} breaker=#{breaker.failures}"

    assert breaker.successes == model.successes,
           "successes mismatch: model=#{model.successes} breaker=#{breaker.successes}"
  end

  defp breaker_pid do
    [{pid, _}] = Registry.lookup(Arrea.CircuitBreaker.Registry, @test_id)
    pid
  end

  defp reset_breaker(pid) do
    :sys.replace_state(pid, fn _ ->
      %Arrea.CircuitBreaker.State{name: @test_id, threshold: @threshold, timeout: 100_000}
    end)
  end
end
