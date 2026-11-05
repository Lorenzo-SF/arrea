defmodule Arrea.WorkerTest do
  use ExUnit.Case

  alias Arrea.Worker

  setup do
    if Process.whereis(Arrea.Registry) == nil do
      start_supervised!({Registry, keys: :unique, name: Arrea.Registry})
    end

    if Process.whereis(Arrea.Monitor) == nil do
      start_supervised!(Arrea.Monitor)
    end

    :ok
  end

  # Este bloque no existe por cobertura. Existe porque `send_message/2`
  # devolvia `:ok` para un worker que NUNCA EXISTIO, y porque lo mismo hace hoy
  # `get_state/1` tres funciones mas abajo y el reenvio interno ya notifica
  # `:message_target_not_found`. El fichero sabia hacerlo; la entrada publica no.
  describe "send_message/2 no miente" do
    test "a worker vivo devuelve :ok" do
      # Con `tasks: []` el worker se queda vivo: no tiene nada que ejecutar y
      # solo sale cuando se le dice. Por eso `Registry.lookup/1` lo encuentra.
      {:ok, pid} = Worker.start_link(id: :vivo, tasks: [], parent: self())
      assert Worker.send_message(:vivo, %{type: :ping}) == :ok
      assert is_pid(Process.alive?(pid) && pid)
    end

    test "a un worker que no existe dice que no existe, y no :ok" do
      # El precondicional: no hay nadie con ese id. Sin esto, el test pasaria
      # igual si el worker existiera y el fix no hiciera nada.
      assert Registry.lookup(Arrea.Registry, :NUNCA_EXISTIO) == []

      assert Worker.send_message(:NUNCA_EXISTIO, %{type: :ping}) ==
               {:error, :worker_not_found}
    end

    test "a un worker que ha muerto dice que no existe" do
      {:ok, pid} = Worker.start_link(id: :muere, tasks: [], parent: self())
      ref = Process.monitor(pid)
      GenServer.stop(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}

      assert Worker.send_message(:muere, %{type: :ping}) ==
               {:error, :worker_not_found}
    end

    test "el @spec declara el error, y si vuelve a decir :ok esto falla" do
      # El `@spec` es lo unico que dialyzer lee de esta funcion. Si vuelve a
      # `:ok` mientras el codigo devuelve el error, dialyzer confirma la mentira
      # y este test se cae.
      #
      # Se lee del FUENTE y no de `Code.Typespec` a proposito: el AST de los
      # typespec cambia entre versiones de Erlang, y un test de contrato que se
      # rompe al actualizar el compilador teaches a ignorar el rojo. El
      # contrato que nos importa es el texto que dialyzer va a leer.
      fuente =
        Arrea.Worker.__info__(:compile)[:source]
        |> Keyword.get(:file, "lib/arrea/worker.ex")
        |> File.read!()

      spec =
        fuente
        |> String.split("\n")
        |> Enum.find(&String.starts_with?(&1, "  @spec send_message"))

      assert spec, "no encuentro el @spec de send_message/2 en el fuente"

      assert spec =~ ":ok",
             "el @spec ya no declara `:ok`: #{inspect(spec)}"

      assert spec =~ ":error" and spec =~ ":worker_not_found",
             "el @spec no declara `{:error, :worker_not_found}` (#{inspect(spec)}): " <>
               "el contrato vuelve a mentir aunque el codigo no lo haga"
    end
  end

  describe "worker lifecycle" do
    test "processes single function task successfully" do
      parent = self()

      task_fn = fn ->
        send(parent, :worker_task_executed)
        {:ok, :result}
      end

      {:ok, _pid} = Worker.start_link(id: :test_worker_1, tasks: [task_fn], parent: parent)

      assert_receive :worker_task_executed, 500
      assert_receive {:worker_done, :test_worker_1, :result}, 500
    end

    test "handles crashing task gracefully" do
      parent = self()
      Process.flag(:trap_exit, true)

      task_fn = fn ->
        raise "Oops"
      end

      {:ok, pid} =
        Worker.start_link(
          id: :test_worker_faulty,
          tasks: [task_fn],
          parent: parent,
          policy: %{max_retries: 0}
        )

      assert_receive {:worker_error, :test_worker_faulty,
                      {:error, {:exception, %RuntimeError{message: "Oops"}}}},
                     500

      assert_receive {:EXIT, ^pid,
                      {:error, {:error, {:exception, %RuntimeError{message: "Oops"}}}}},
                     500
    end

    test "processes multiple tasks sequentially" do
      parent = self()

      task_fn1 = fn ->
        send(parent, :task1)
        {:ok, 1}
      end

      task_fn2 = fn ->
        send(parent, :task2)
        {:ok, 2}
      end

      Process.flag(:trap_exit, true)

      {:ok, _pid} =
        Worker.start_link(id: :test_worker_multi, tasks: [task_fn1, task_fn2], parent: parent)

      assert_receive :task1, 500
      assert_receive {:worker_done, :test_worker_multi, 1}, 500
      assert_receive :task2, 500
      assert_receive {:worker_done, :test_worker_multi, 2}, 500
    end

    test "supports pause and get_state" do
      task_fn = fn -> :noop end
      {:ok, pid} = Worker.start_link(id: :test_state_worker, tasks: [task_fn])
      assert {:ok, state} = GenServer.call(pid, :get_state)
      assert state.id == :test_state_worker

      assert :ok = GenServer.call(pid, :pause)
    end

    test "handles on_error: :stop policy" do
      parent = self()
      Process.flag(:trap_exit, true)

      task = fn -> raise "fail" end

      {:ok, pid} =
        Worker.start_link(
          id: :test_stop_worker,
          tasks: [task],
          parent: parent,
          policy: %{on_error: :stop, max_retries: 0}
        )

      assert_receive {:worker_error, :test_stop_worker,
                      {:error, {:exception, %RuntimeError{message: "fail"}}}},
                     500

      assert_receive {:EXIT, ^pid,
                      {:error, {:error, {:exception, %RuntimeError{message: "fail"}}}}},
                     500
    end

    test "handles on_error: :continue policy" do
      parent = self()
      Process.flag(:trap_exit, true)

      task = fn -> raise "fail" end

      {:ok, pid} =
        Worker.start_link(
          id: :test_continue_worker,
          tasks: [task],
          parent: parent,
          policy: %{on_error: :continue}
        )

      # With :continue policy, the error is skipped and the worker stops normally
      assert_receive {:EXIT, ^pid, :normal}, 500
    end

    test "handles generic catch in task execution" do
      parent = self()
      Process.flag(:trap_exit, true)

      task = fn -> throw(:some_error) end

      {:ok, pid} =
        Worker.start_link(
          id: :test_catch_worker,
          tasks: [task],
          parent: parent,
          policy: %{max_retries: 0}
        )

      assert_receive {:worker_error, :test_catch_worker, {:error, {:throw, :some_error}}}, 500
      assert_receive {:EXIT, ^pid, {:error, {:error, {:throw, :some_error}}}}, 500
    end
  end
end
