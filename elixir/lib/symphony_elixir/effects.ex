defmodule SymphonyElixir.Effects do
  @moduledoc """
  Deterministic ids for tracker writes.

  An id is derived from what the write is (issue, stage, summary, report), so
  retrying the same write after a crash reuses the same id and the tracker
  refuses the duplicate instead of posting it twice.
  """

  import Bitwise

  @doc """
  A deterministic UUID v4-formatted string derived from `key`.
  """
  @spec uuid(String.t()) :: String.t()
  def uuid(key) when is_binary(key) do
    <<a::32, b::16, c::16, d::16, e::48>> = binary_part(:crypto.hash(:sha256, key), 0, 16)

    hex =
      Base.encode16(
        <<a::32, b::16, band(c, 0x0FFF) ||| 0x4000::16, band(d, 0x3FFF) ||| 0x8000::16, e::48>>,
        case: :lower
      )

    <<p1::binary-size(8), p2::binary-size(4), p3::binary-size(4), p4::binary-size(4), p5::binary>> = hex
    Enum.join([p1, p2, p3, p4, p5], "-")
  end
end
