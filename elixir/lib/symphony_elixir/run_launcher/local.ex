defmodule SymphonyElixir.RunLauncher.Local do
  @moduledoc """
  The in-process launcher: each run is a task under
  `SymphonyElixir.TaskSupervisor`, exactly as the orchestrator started runs
  before the launcher seam existed.

  A reference is `"local:" <> boot_id <> ":" <> pid`, where the boot id is a
  random token made once per VM boot. A reference from a previous boot (or any
  reference that doesn't parse) is never alive, so a restarted controller does
  not mistake a recycled pid for the run it used to be.
  """

  @behaviour SymphonyElixir.RunLauncher

  @boot_id_key {__MODULE__, :boot_id}
  @prefix "local:"

  @doc "This VM boot's random token; the same for the life of the VM."
  @spec boot_id() :: String.t()
  def boot_id do
    case :persistent_term.get(@boot_id_key, nil) do
      nil ->
        boot_id = Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
        :persistent_term.put(@boot_id_key, boot_id)
        boot_id

      boot_id ->
        boot_id
    end
  end

  @doc "The reference for a pid in this boot."
  @spec ref_for(pid()) :: String.t()
  def ref_for(pid) when is_pid(pid), do: @prefix <> boot_id() <> ":" <> pid_string(pid)

  @impl true
  def start(fun, _opts) when is_function(fun, 0) do
    with {:ok, pid} <- Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fun) do
      {:ok, pid, ref_for(pid)}
    end
  catch
    :exit, reason -> {:error, reason}
  end

  @impl true
  def alive?(ref) when is_binary(ref) do
    current_boot_id = boot_id()

    case parse_ref(ref) do
      {:ok, ^current_boot_id, pid} -> Process.alive?(pid)
      _ -> false
    end
  end

  def alive?(_ref), do: false

  @impl true
  def stop(ref) do
    current_boot_id = boot_id()

    case parse_ref(ref) do
      {:ok, ^current_boot_id, pid} ->
        if Process.alive?(pid) do
          Task.Supervisor.terminate_child(SymphonyElixir.TaskSupervisor, pid)
        end

      _ ->
        :ok
    end

    :ok
  end

  defp parse_ref(ref) do
    with ["local", boot_id, pid_string] <- String.split(ref, ":"),
         {:ok, pid} <- parse_pid(pid_string) do
      {:ok, boot_id, pid}
    else
      _ -> :error
    end
  end

  defp pid_string(pid), do: pid |> :erlang.pid_to_list() |> List.to_string() |> String.trim_leading("<") |> String.trim_trailing(">")

  defp parse_pid(pid_string) do
    {:ok, :erlang.list_to_pid(~c"<#{pid_string}>")}
  rescue
    ArgumentError -> :error
  end
end
