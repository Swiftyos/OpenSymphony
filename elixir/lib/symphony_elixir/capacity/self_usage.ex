defmodule SymphonyElixir.Capacity.SelfUsage do
  @moduledoc """
  The CPU time and memory of the run this runner is, measured from inside it.

  A runner pod (or a process runner in its own systemd unit) cannot be seen by
  the controller's `ps` or `podman stats`, so the runner measures itself and
  reports it in `metrics` events (`SymphonyElixir.Capacity.UsageReporter`).
  The first source that works wins:

    1. **cgroup v2** — `cpu.stat` (`usage_usec`) and `memory.current` minus
       `memory.stat`'s `inactive_file` (the working set, as the kubelet and
       `kubectl top` count it) of the runner's own cgroup.
    2. **cgroup v1** — `cpuacct.usage` and `memory.usage_in_bytes` minus
       `total_inactive_file`.
    3. **proc** — the runner's own process tree in `/proc`: `utime`, `stime`
       and the reaped children's `cutime`/`cstime`, and resident memory. It
       double-counts shared pages, like the VM sampler's `ps`.

  A cgroup is only used when it is the run's own: the root of a namespaced
  cgroup (`/`, what a container sees) or a `symphony-run-*` systemd unit.
  Anything else (a runner started inside `symphony.service`, a non-namespaced
  container) would measure more than the run, so the process tree is used.

  Under gVisor (GKE Sandbox) the sandbox's kernel decides which of these it
  emulates; the sample says which one answered (`source`), and
  `symphony_run_usage_reports_total{source}` shows it per controller.
  """

  @type sample :: %{cpu_seconds: float(), memory_bytes: non_neg_integer(), source: String.t()}

  @clock_ticks_per_second 100
  @page_size 4096

  @doc """
  Reads the usage. Options: `:root` (the filesystem root, `/`; tests point it
  at a fake tree) and `:pid` (the process tree's root, the runner's own OS pid).
  """
  @spec read(keyword()) :: {:ok, sample()} | {:error, :unavailable}
  def read(opts \\ []) do
    root = Keyword.get(opts, :root, "/")
    pid = Keyword.get_lazy(opts, :pid, fn -> String.to_integer(System.pid()) end)
    cgroups = cgroups(root)

    with nil <- cgroup_v2(root, cgroups),
         nil <- cgroup_v1(root, cgroups),
         nil <- proc_tree(root, pid) do
      {:error, :unavailable}
    else
      sample -> {:ok, sample}
    end
  end

  # /proc/self/cgroup: "hierarchy:controllers:path" per line.
  defp cgroups(root) do
    case File.read(Path.join(root, "proc/self/cgroup")) do
      {:ok, contents} ->
        for line <- String.split(contents, "\n", trim: true),
            [_id, controllers, path] <- [String.split(line, ":", parts: 3)],
            do: {String.split(controllers, ",", trim: true), path}

      {:error, _reason} ->
        []
    end
  end

  defp cgroup_v2(root, cgroups) do
    with {[], path} <- Enum.find(cgroups, &match?({[], _path}, &1)),
         true <- own_cgroup?(path),
         dir = cgroup_dir(root, "", path),
         {:ok, usage_usec} <- stat_field(Path.join(dir, "cpu.stat"), "usage_usec"),
         {:ok, current} <- integer_file(Path.join(dir, "memory.current")) do
      inactive = optional_stat(Path.join(dir, "memory.stat"), "inactive_file")
      %{cpu_seconds: usage_usec / 1_000_000, memory_bytes: max(current - inactive, 0), source: "cgroup_v2"}
    else
      _unavailable -> nil
    end
  end

  defp cgroup_v1(root, cgroups) do
    with {_controllers, cpu_path} <- Enum.find(cgroups, fn {controllers, _path} -> "cpuacct" in controllers end),
         {_controllers, memory_path} <- Enum.find(cgroups, fn {controllers, _path} -> "memory" in controllers end),
         true <- own_cgroup?(cpu_path) and own_cgroup?(memory_path),
         {:ok, usage_ns} <- first_integer_file(for(mount <- ["cpuacct", "cpu,cpuacct", "cpuacct,cpu"], do: Path.join(cgroup_dir(root, mount, cpu_path), "cpuacct.usage"))),
         memory_dir = cgroup_dir(root, "memory", memory_path),
         {:ok, usage} <- integer_file(Path.join(memory_dir, "memory.usage_in_bytes")) do
      inactive = optional_stat(Path.join(memory_dir, "memory.stat"), "total_inactive_file")
      %{cpu_seconds: usage_ns / 1_000_000_000, memory_bytes: max(usage - inactive, 0), source: "cgroup_v1"}
    else
      _unavailable -> nil
    end
  end

  defp own_cgroup?("/"), do: true
  defp own_cgroup?(path), do: path |> Path.basename() |> String.starts_with?("symphony-run-")

  defp cgroup_dir(root, mount, path), do: Path.join([root, "sys/fs/cgroup", mount, String.trim_leading(path, "/")])

  defp proc_tree(root, pid) do
    processes = read_processes(Path.join(root, "proc"))

    if Map.has_key?(processes, pid) do
      children = Enum.group_by(processes, fn {_pid, process} -> process.ppid end, fn {child, _process} -> child end)
      tree = descendants([pid], children, MapSet.new())
      {ticks, pages} = Enum.reduce(tree, {0, 0}, fn member, {ticks, pages} -> {ticks + processes[member].ticks, pages + processes[member].rss_pages} end)
      %{cpu_seconds: ticks / @clock_ticks_per_second, memory_bytes: pages * @page_size, source: "proc"}
    end
  end

  defp descendants([], _children, seen), do: seen

  defp descendants([pid | rest], children, seen) do
    if MapSet.member?(seen, pid),
      do: descendants(rest, children, seen),
      else: descendants(Map.get(children, pid, []) ++ rest, children, MapSet.put(seen, pid))
  end

  defp read_processes(proc) do
    case File.ls(proc) do
      {:ok, entries} ->
        for entry <- entries,
            {pid, ""} <- [Integer.parse(entry)],
            {:ok, contents} <- [File.read(Path.join([proc, entry, "stat"]))],
            {:ok, process} <- [parse_stat(contents)],
            into: %{},
            do: {pid, process}

      {:error, _reason} ->
        %{}
    end
  end

  @doc false
  # /proc/<pid>/stat after "(comm)" (which may hold spaces and parens): state
  # is field 3, ppid 4, utime..cstime 14..17 and rss (pages) 24.
  @spec parse_stat(String.t()) :: {:ok, %{ppid: integer(), ticks: integer(), rss_pages: integer()}} | :error
  def parse_stat(contents) do
    with [_before, rest] <- split_after_comm(contents),
         fields = String.split(rest),
         [_state, ppid | _] <- fields,
         [utime, stime, cutime, cstime] <- Enum.slice(fields, 11, 4),
         [rss] <- Enum.slice(fields, 21, 1),
         {:ok, [ppid, utime, stime, cutime, cstime, rss]} <- integers([ppid, utime, stime, cutime, cstime, rss]) do
      {:ok, %{ppid: ppid, ticks: utime + stime + cutime + cstime, rss_pages: max(rss, 0)}}
    else
      _invalid -> :error
    end
  end

  defp split_after_comm(contents) do
    case :binary.matches(contents, ") ") do
      [] ->
        :error

      matches ->
        {position, length} = List.last(matches)
        rest_start = position + length
        [binary_part(contents, 0, position), binary_part(contents, rest_start, byte_size(contents) - rest_start)]
    end
  end

  defp integers(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case Integer.parse(value) do
        {integer, ""} -> {:cont, {:ok, acc ++ [integer]}}
        _invalid -> {:halt, :error}
      end
    end)
  end

  defp integer_file(path) do
    with {:ok, contents} <- File.read(path),
         {integer, _rest} <- Integer.parse(String.trim(contents)) do
      {:ok, integer}
    else
      _unavailable -> :error
    end
  end

  defp first_integer_file(paths), do: Enum.find_value(paths, :error, &ok_or_nil(integer_file(&1)))

  defp ok_or_nil({:ok, _value} = ok), do: ok
  defp ok_or_nil(_error), do: nil

  # "key value" lines (cpu.stat, memory.stat).
  defp stat_field(path, key) do
    with {:ok, contents} <- File.read(path),
         [_key, value] <- Enum.find_value(String.split(contents, "\n"), &key_line(&1, key)),
         {integer, ""} <- Integer.parse(value) do
      {:ok, integer}
    else
      _unavailable -> :error
    end
  end

  defp key_line(line, key) do
    case String.split(line) do
      [^key, _value] = pair -> pair
      _other -> nil
    end
  end

  defp optional_stat(path, key) do
    case stat_field(path, key) do
      {:ok, value} -> value
      :error -> 0
    end
  end
end
