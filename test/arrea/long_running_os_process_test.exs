defmodule Arrea.LongRunning.OsProcessTest do
  @moduledoc """
  `stop/1` tiene que parar el proceso del SISTEMA OPERATIVO, no el GenServer.

  Antes, `stop/1` hacia `GenServer.stop/1` y devolvia `:ok`, y el proceso
  seguia vivo. Cerrar el puerto no lo mata: un
  `Port.open({:spawn_executable, _})` deja al binario como hijo de la maquina, y
  al cerrarlo solo se cierra el descriptor. El proceso se queda huerfano,
  reparteado a init.

  Y no era un detalle teorico: en Candil, `candil stop` decia "instancias
  paradas" mientras un `llama-server` de 17 GB seguia con la VRAM cogida, sin
  que `candil status` lo supiera. Dos herramientas diciendo verdad sobre cosas
  distintas, y la que decia "parado" mintiendo.
  """
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  @tag timeout: 60_000
  test "stop/1 deja el proceso del SO muerto", %{tmp_dir: tmp_dir} do
    {bin, pidfile} = sleeper(tmp_dir)
    id = {:test, :stop_kills_os_process}

    {:ok, _lr} = Arrea.LongRunning.start_link(id: id, binary: bin, args: [])
    os_pid = wait_for_pid(pidfile)

    assert alive?(os_pid), "el proceso deberia estar vivo antes de parar"

    assert :ok = Arrea.LongRunning.stop(id)

    assert eventually_dead?(os_pid),
           "stop/1 ha devuelto :ok y el proceso #{os_pid} sigue vivo. " <>
             "Un puerto cerrado no es un proceso parado."
  end

  @tag timeout: 60_000
  test "un proceso que se para a si mismo tambien se limpia", %{tmp_dir: tmp_dir} do
    {bin, pidfile} = sleeper(tmp_dir)
    id = {:test, :self_stopping}

    {:ok, _lr} = Arrea.LongRunning.start_link(id: id, binary: bin, args: [])
    os_pid = wait_for_pid(pidfile)
    assert alive?(os_pid)

    GenServer.stop(pid = Process.whereis(Arrea.Registry) && lookup(id), :normal, 5_000)
    _ = pid

    assert eventually_dead?(os_pid)
  end

  defp lookup(id) do
    [{pid, _}] = Registry.lookup(Arrea.Registry, id)
    pid
  end

  # Un script que escribe su pid y se queda. `exec -a` no se usa porque es de
  # bash y no de sh, y sale con 127 sin que se note por que.
  defp sleeper(tmp_dir) do
    bin = Path.join(tmp_dir, "sleeper-#{System.unique_integer([:positive])}")
    pidfile = Path.join(tmp_dir, "sleeper.pid")
    File.write!(bin, "#!/bin/sh\necho $$ > #{pidfile}\nsleep 600\n")
    File.chmod!(bin, 0o755)
    {bin, pidfile}
  end

  defp wait_for_pid(path, tries \\ 50) do
    case File.read(path) do
      {:ok, contents} ->
        case contents |> String.trim() |> Integer.parse() do
          {pid, _} -> pid
          :error -> retry(path, tries)
        end

      _ ->
        retry(path, tries)
    end
  end

  defp retry(_path, 0), do: nil
  defp retry(path, tries), do: Process.sleep(100) && wait_for_pid(path, tries - 1)

  defp alive?(os_pid) do
    # Sin `stderr_to_stdout`, cada `alive?/1` sobre un proceso ya muerto escribe
    # "No such process" por consola y el test parece fallar por ruido.
    {_out, code} = System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true)
    code == 0
  end

  defp eventually_dead?(os_pid, tries \\ 50) do
    cond do
      not alive?(os_pid) -> true
      tries == 0 -> false
      true -> Process.sleep(100) && eventually_dead?(os_pid, tries - 1)
    end
  end
end
