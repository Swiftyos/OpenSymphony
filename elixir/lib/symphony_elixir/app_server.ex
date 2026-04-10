defmodule SymphonyElixir.AppServer do
  @moduledoc """
  Dispatches agent app-server operations to the configured backend.
  """

  alias SymphonyElixir.ClaudeCode.AppServer, as: ClaudeCodeAppServer
  alias SymphonyElixir.Codex.AppServer, as: CodexAppServer
  alias SymphonyElixir.Config
  alias SymphonyElixir.OpenCode.AppServer, as: OpenCodeAppServer

  @spec run(Path.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(workspace, prompt, issue, opts \\ []) do
    backend_module().run(workspace, prompt, issue, opts)
  end

  @spec start_session(Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def start_session(workspace, opts \\ []) do
    backend_module().start_session(workspace, opts)
  end

  @spec run_turn(map(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(session, prompt, issue, opts \\ []) do
    backend_module().run_turn(session, prompt, issue, opts)
  end

  @spec stop_session(map()) :: :ok
  def stop_session(session) do
    backend_module().stop_session(session)
  end

  @spec backend_module() :: module()
  def backend_module do
    case Config.agent_backend() do
      "opencode" -> OpenCodeAppServer
      "claude" -> ClaudeCodeAppServer
      _ -> CodexAppServer
    end
  end
end
