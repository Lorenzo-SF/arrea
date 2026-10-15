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
  # ── `state/1` dice que proceso es ──────────────────────────────────────────
  #
  # El snapshot dice `running: state.port != nil`, que es verdad y no dice nada
  # de QUE proceso. Para quien esto importa de verdad —mandarle una senal desde
  # fuera del BEAM, atribuirle CPU o memoria con una herramienta que no es
  # Erlang, o entregarlo a un supervisor de procesos— el pid del BEAM no sirve:
  # `ps`, `kill`, `nvidia-smi` y cgroups hablan el pid del SISTEMA OPERATIVO.
  #
  # Y el pid es justo lo que `stop/1` usa por dentro para matarlo, asi que no es
  # un dato raro: es el mismo, solo que hacia afuera.

  @tag timeout: 60_000
  test "state/1 dice el pid del SISTEMA OPERATIVO, no el del GenServer", %{
    tmp_dir: tmp_dir
  } do
    {bin, pidfile} = sleeper(tmp_dir)
    id = {:test, :state_reports_os_pid}

    {:ok, _lr} = Arrea.LongRunning.start_link(id: id, binary: bin, args: [])

    # El pid lo escribe el PROCESO con su propio `$$`, o sea que viene del
    # punto de vista de quien seraidentifyado, no del que lo lanza.
    os_pid = wait_for_pid(pidfile)

    assert {:ok, snapshot} = Arrea.LongRunning.state(id)

    assert snapshot.os_pid == os_pid,
           "state/1 dice #{inspect(snapshot.os_pid)} y el proceso es #{os_pid}"
  end

  # No hay un test del `nil`: `stop/1` y la muerte del proceso **terminan el
  # GenServer**, asi que una vez que el proceso no esta, `state/1` responde
  # `{:error, :not_found}` y no hay instantanea que mirar. El `nil` solo existe
  # en el hueco entre que el proceso muere y que el puerto avisa, y ese hueco no
  # se puede asserting sin ragarse.

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
