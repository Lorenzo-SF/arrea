defmodule Arrea.CircuitBreaker.StateTest do
  use ExUnit.Case, async: true

  alias Arrea.CircuitBreaker.State

  describe "struct" do
    test "default values" do
      state = %State{}
      assert state.failures == 0
      assert state.state == :closed
      assert state.successes == 0
      assert state.last_failure_at == nil
    end

    test "can be set to half_open" do
      state = %State{state: :half_open}
      assert state.state == :half_open
    end

    test "can be set to open" do
      state = %State{state: :open}
      assert state.state == :open
    end
  end
end
