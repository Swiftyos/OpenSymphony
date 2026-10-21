defmodule SymphonyElixir.AgentInbox do
  @moduledoc """
  Messages people send from the dashboard to the agent working on an issue.

  A message is first `"queued"`. It is delivered one of two ways:

    * `"steered"`: a Codex turn is running for the issue, so the runner process
      (which owns the app-server port) sends it into that turn with
      `turn/steer`.
    * `"next_turn"`: otherwise (Claude Code, OpenCode, Codex between turns, or
      no agent running) it waits and is prepended to the next turn prompt any
      agent runs for that issue.

  Claude Code is never interrupted mid-turn: its stream-json mode treats every
  user line as a new turn with its own `result`, so injecting one while a turn
  is running would split the turn and confuse result handling.

  Messages are kept in memory (the newest #{100} per issue). Queued ones are
  also written to `~/.symphony/inbox.json` so a restart doesn't lose them.

  Runner processes register under the issue identifier in
  `SymphonyElixir.AgentInbox.Registry` while they run; a Codex runner also
  records its active thread and turn ids there, which is how a new message
  finds the process to steer.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.Transcript

  @table :symphony_agent_inbox
  @registry SymphonyElixir.AgentInbox.Registry
  @max_per_issue 100
  @max_text 8_000
  @format_version 1

  @type message :: %{
          id: String.t(),
          issue_id: String.t() | nil,
          identifier: String.t(),
          author: String.t(),
          text: String.t(),
          at: DateTime.t(),
          status: String.t(),
          delivered_at: DateTime.t() | nil,
          delivery: String.t() | nil
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc false
  @spec registry() :: atom()
  def registry, do: @registry

  @doc """
  Sends `text` from `author` to the agent working on `identifier` (e.g.
  `"PAY-12"`). Records a `"user"` transcript entry, then steers a running Codex
  turn or queues the message for the next turn.
  """
  @spec send_message(String.t(), String.t(), String.t() | nil) :: {:ok, message()} | {:error, atom()}
  def send_message(identifier, text, author) do
    with {:ok, identifier} <- validate_identifier(identifier),
         {:ok, text} <- validate_text(text),
         true <- ready?() || {:error, :unavailable} do
      call({:send, identifier, text, normalize_author(author)}, {:error, :unavailable})
    end
  end

  @doc """
  The issue's messages, oldest first.
  """
  @spec messages(String.t() | nil) :: [message()]
  def messages(identifier) when is_binary(identifier) do
    if ready?() do
      @table
      |> :ets.match_object({:_, identifier, :_})
      |> Enum.map(&elem(&1, 2))
      |> Enum.sort_by(&order_key/1)
    else
      []
    end
  end

  def messages(_identifier), do: []

  @doc """
  One message, if it exists for that issue.
  """
  @spec get(String.t(), String.t()) :: message() | nil
  def get(identifier, id) when is_binary(identifier) and is_binary(id) do
    with true <- ready?(), [{^id, ^identifier, message}] <- :ets.lookup(@table, id) do
      message
    else
      _ -> nil
    end
  end

  def get(_identifier, _id), do: nil

  @doc """
  Marks every queued message for the issue delivered with `"next_turn"` and
  returns them, oldest first. The agent runner calls this as it builds a turn
  prompt.
  """
  @spec take_queued(String.t() | nil) :: [message()]
  def take_queued(identifier) when is_binary(identifier) do
    if ready?() and Enum.any?(messages(identifier), &(&1.status == "queued")) do
      call({:take_queued, identifier}, [])
    else
      []
    end
  end

  def take_queued(_identifier), do: []

  @doc """
  Whether the issue has messages that haven't reached an agent yet.
  """
  @spec queued?(String.t() | nil) :: boolean()
  def queued?(identifier), do: Enum.any?(messages(identifier), &(&1.status == "queued"))

  @doc """
  Marks one message delivered (`delivery` is `"steered"` or `"next_turn"`).
  """
  @spec mark_delivered(String.t(), String.t(), String.t()) :: :ok
  def mark_delivered(identifier, id, delivery) when is_binary(identifier) and is_binary(id) do
    if ready?(), do: call({:mark_delivered, identifier, id, delivery}, :ok), else: :ok
  end

  @doc """
  The prompt section announcing messages to the agent, or `""` for none.
  """
  @spec prompt_section([message()]) :: String.t()
  def prompt_section([]), do: ""

  def prompt_section(messages) when is_list(messages) do
    authors = messages |> Enum.map(& &1.author) |> Enum.uniq() |> Enum.join(", ")
    noun = if length(messages) == 1, do: "Message", else: "Messages"

    body =
      Enum.map_join(messages, "\n\n", fn message ->
        "[#{Calendar.strftime(message.at, "%Y-%m-%d %H:%M UTC")}] #{message.author}:\n#{message.text}"
      end)

    """
    ======== #{noun} from #{authors} via the Symphony dashboard ========
    A person watching this issue sent you the following. Read it first and take it into account
    for this turn; answer any question in your reply, which they will see on the dashboard.

    #{body}
    ======== End of dashboard messages ========

    """
  end

  @doc """
  The text sent into a running Codex turn with `turn/steer`.
  """
  @spec steer_text(message()) :: String.t()
  def steer_text(message) do
    "Message from #{message.author} via the Symphony dashboard:\n\n#{message.text}"
  end

  @doc false
  @spec reset() :: :ok
  def reset, do: if(ready?(), do: call(:reset, :ok), else: :ok)

  # ------------------------------------------------------------------ runners

  @doc """
  Registers the calling process as the runner for `issue` (an issue with an
  `identifier`) for the rest of its life or until `unregister_runner/1`.
  """
  @spec register_runner(map(), String.t() | nil) :: :ok
  def register_runner(%{identifier: identifier} = issue, backend) when is_binary(identifier) do
    if registry_ready?() do
      _ = Registry.unregister(@registry, identifier)
      _ = Registry.register(@registry, identifier, %{issue_id: Map.get(issue, :id), backend: backend, steer: nil})
    end

    :ok
  end

  def register_runner(_issue, _backend), do: :ok

  @spec unregister_runner(String.t() | nil) :: :ok
  def unregister_runner(identifier) when is_binary(identifier) do
    if registry_ready?(), do: Registry.unregister(@registry, identifier)
    :ok
  end

  def unregister_runner(_identifier), do: :ok

  @doc """
  Called by the Codex runner when a turn starts (`steer` = `%{thread_id,
  turn_id}`) or ends (`nil`). While a turn is active, new messages are sent to
  the runner as `{:agent_inbox, message_id}`. On start, messages queued while
  the turn was being set up are sent too.
  """
  @spec codex_turn(map(), %{thread_id: String.t(), turn_id: String.t()} | nil) :: :ok
  def codex_turn(%{identifier: identifier} = issue, steer) when is_binary(identifier) do
    if registry_ready?() do
      put_steer(issue, steer)
      if steer, do: hand_over_queued(identifier)
    end

    :ok
  end

  def codex_turn(_issue, _steer), do: :ok

  defp hand_over_queued(identifier) do
    for %{status: "queued", id: id} <- messages(identifier), do: send(self(), {:agent_inbox, id})
  end

  defp put_steer(%{identifier: identifier} = issue, steer) do
    case Registry.update_value(@registry, identifier, &Map.put(&1, :steer, steer)) do
      :error -> Registry.register(@registry, identifier, %{issue_id: Map.get(issue, :id), backend: "codex", steer: steer})
      _ -> :ok
    end
  end

  # ------------------------------------------------------------------ server

  @impl true
  def init(opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    path = Keyword.get(opts, :path, default_path())
    load(path)
    {:ok, %{path: path}}
  end

  @impl true
  def handle_call({:send, identifier, text, author}, _from, state) do
    now = DateTime.utc_now()

    message = %{
      id: "msg_" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false),
      issue_id: runner_value(identifier)[:issue_id],
      identifier: identifier,
      author: author,
      text: text,
      at: now,
      status: "queued",
      delivered_at: nil,
      delivery: nil
    }

    put(message)
    prune(identifier)

    Transcript.user_message(identifier, message)
    persist(state.path)

    case runner_value(identifier) do
      %{steer: %{}, pid: pid} -> send(pid, {:agent_inbox, message.id})
      _ -> :ok
    end

    broadcast()
    {:reply, {:ok, message}, state}
  end

  def handle_call({:take_queued, identifier}, _from, state) do
    now = DateTime.utc_now()

    taken =
      for %{status: "queued"} = message <- messages(identifier) do
        delivered = %{message | status: "delivered", delivered_at: now, delivery: "next_turn"}
        put(delivered)
        Transcript.message_delivered(identifier, delivered)
        delivered
      end

    if taken != [] do
      persist(state.path)
      broadcast()
    end

    {:reply, taken, state}
  end

  def handle_call({:mark_delivered, identifier, id, delivery}, _from, state) do
    case get(identifier, id) do
      %{status: "queued"} = message ->
        delivered = %{message | status: "delivered", delivered_at: DateTime.utc_now(), delivery: delivery}
        put(delivered)
        Transcript.message_delivered(identifier, delivered)
        persist(state.path)
        broadcast()

      _ ->
        :ok
    end

    {:reply, :ok, state}
  end

  def handle_call(:reset, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, state}
  end

  # ------------------------------------------------------------------ helpers

  defp call(request, fallback) do
    GenServer.call(__MODULE__, request)
  catch
    :exit, reason ->
      Logger.warning("Agent inbox unavailable request=#{inspect(request_name(request))} reason=#{inspect(reason, limit: 5)}")
      fallback
  end

  defp request_name(request) when is_tuple(request), do: elem(request, 0)
  defp request_name(request), do: request

  defp put(message), do: :ets.insert(@table, {message.id, message.identifier, message})

  defp prune(identifier) do
    all = messages(identifier)
    extra = length(all) - @max_per_issue

    if extra > 0 do
      # Oldest delivered first; queued ones only when there are too many of those alone.
      {delivered, queued} = Enum.split_with(all, &(&1.status != "queued"))
      Enum.each(Enum.take(delivered ++ queued, extra), &:ets.delete(@table, &1.id))
    end
  end

  defp order_key(message), do: {DateTime.to_unix(message.at, :microsecond), message.id}

  defp runner_value(identifier) do
    if registry_ready?() do
      case Registry.lookup(@registry, identifier) do
        [{pid, value} | _] -> Map.put(value, :pid, pid)
        [] -> nil
      end
    end
  end

  defp validate_identifier(identifier) when is_binary(identifier) do
    case String.trim(identifier) do
      "" -> {:error, :invalid_identifier}
      trimmed -> {:ok, trimmed}
    end
  end

  defp validate_identifier(_identifier), do: {:error, :invalid_identifier}

  defp validate_text(text) when is_binary(text) do
    trimmed = String.trim(text)

    cond do
      trimmed == "" -> {:error, :empty_message}
      String.length(trimmed) > @max_text -> {:error, :message_too_long}
      true -> {:ok, trimmed}
    end
  end

  defp validate_text(_text), do: {:error, :empty_message}

  defp normalize_author(author) when is_binary(author) do
    case String.trim(author) do
      "" -> "Someone"
      trimmed -> String.slice(trimmed, 0, 200)
    end
  end

  defp normalize_author(_author), do: "Someone"

  defp ready?, do: :ets.whereis(@table) != :undefined
  defp registry_ready?, do: Process.whereis(@registry) != nil

  defp broadcast, do: SymphonyElixirWeb.ObservabilityPubSub.broadcast_update()

  defp default_path do
    case Application.get_env(:symphony_elixir, :agent_inbox_path, :default) do
      :default -> Path.expand("~/.symphony/inbox.json")
      path -> path
    end
  end

  # Only queued messages are worth keeping across a restart.
  defp persist(nil), do: :ok

  defp persist(path) do
    queued = for {_id, _identifier, %{status: "queued"} = message} <- :ets.tab2list(@table), do: message
    body = Jason.encode!(%{version: @format_version, queued: Enum.sort_by(queued, &order_key/1)})

    case SymphonyElixir.StateStore.write(path, body) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Agent inbox write failed path=#{path} reason=#{inspect(reason)}")
    end
  end

  defp load(nil), do: :ok

  defp load(path) do
    with {:ok, body} <- SymphonyElixir.StateStore.read(path),
         {:ok, %{"queued" => queued}} when is_list(queued) <- Jason.decode(body) do
      queued |> Enum.flat_map(&load_message/1) |> Enum.each(&put/1)
    else
      {:error, :enoent} -> :ok
      other -> Logger.warning("Agent inbox load skipped path=#{path} reason=#{inspect(other, limit: 5)}")
    end

    :ok
  end

  defp load_message(%{"id" => id, "identifier" => identifier, "text" => text} = row)
       when is_binary(id) and is_binary(identifier) and is_binary(text) do
    at =
      case DateTime.from_iso8601(to_string(row["at"])) do
        {:ok, at, _offset} -> at
        _ -> DateTime.utc_now()
      end

    [
      %{
        id: id,
        issue_id: row["issue_id"],
        identifier: identifier,
        author: row["author"] || "Someone",
        text: text,
        at: at,
        status: "queued",
        delivered_at: nil,
        delivery: nil
      }
    ]
  end

  defp load_message(_row), do: []
end
