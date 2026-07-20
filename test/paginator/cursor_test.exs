defmodule Paginator.CursorTest do
  use ExUnit.Case, async: true

  alias Paginator.Cursor

  describe "encoding and decoding terms" do
    test "it encodes and decodes map cursors" do
      cursor = Cursor.encode(%{a: 1, b: 2})

      assert Cursor.decode(cursor) == %{a: 1, b: 2}
    end

    # Deterministic cursor encoding improves feeds ETags hit rates
    test "it encodes equivalent map cursors deterministically" do
      values = %{inserted_at: ~U[2026-07-20 18:30:00.123456Z], id: "msg_123"}
      equivalent_values = Map.new(Enum.reverse(Map.to_list(values)))

      expected_cursor =
        values
        |> :erlang.term_to_binary([:deterministic])
        |> Base.url_encode64()

      assert values == equivalent_values
      assert Cursor.encode(values) == expected_cursor
      assert Cursor.encode(equivalent_values) == expected_cursor
    end
  end

  describe "Cursor.decode/1" do
    test "it decodes cursors encoded without deterministic serialization" do
      values = %{inserted_at: ~U[2026-07-20 18:30:00.123456Z], id: "msg_123"}

      legacy_cursor =
        values
        |> :erlang.term_to_binary()
        |> Base.url_encode64()

      assert Cursor.decode(legacy_cursor) == values
    end

    test "it safely decodes user input" do
      assert_raise ArgumentError, fn ->
        # this binary represents the atom :fubar_0a1b2c3d4e
        <<131, 100, 0, 16, "fubar_0a1b2c3d4e">>
        |> Base.url_encode64()
        |> Cursor.decode()
      end
    end
  end
end
