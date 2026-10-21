defmodule SymphonyElixir.EffectsTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Effects

  test "ids are deterministic UUID v4 strings derived from the key" do
    id = Effects.uuid("stage-result:id-PAY-1:review:abc")

    assert id == Effects.uuid("stage-result:id-PAY-1:review:abc")
    assert id =~ ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
  end

  test "different keys give different ids" do
    refute Effects.uuid("one") == Effects.uuid("two")
  end
end
