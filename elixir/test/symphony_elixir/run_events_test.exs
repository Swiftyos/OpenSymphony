defmodule SymphonyElixir.RunEventsTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.RunEvents

  test "encodes and decodes atoms, structs and DateTimes unchanged" do
    term = %{
      event: :turn_completed,
      at: ~U[2026-01-02 03:04:05Z],
      nested: [%{"thread" => "thread-1"}, {:tuple, 2}]
    }

    encoded = RunEvents.encode(term)

    assert is_binary(encoded)
    refute encoded =~ "\n"
    assert {:ok, ^term} = RunEvents.decode(encoded)
  end

  test "garbage is refused, not raised" do
    assert {:error, :invalid} = RunEvents.decode("not base64 !!!")
    assert {:error, :invalid} = RunEvents.decode(Base.encode64("not an erlang term"))
    assert {:error, :invalid} = RunEvents.decode(nil)
    assert {:error, :invalid} = RunEvents.decode(123)
  end
end
