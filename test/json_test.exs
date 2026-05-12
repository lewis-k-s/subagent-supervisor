defmodule CodexSubagents.JSONTest do
  use ExUnit.Case, async: true

  test "encodes maps and escaped strings" do
    assert CodexSubagents.JSON.encode(%{ok: true, output: "a\n\"b\""}) ==
             "{\"ok\":true,\"output\":\"a\\n\\\"b\\\"\"}"
  end

  test "encodes nil" do
    assert CodexSubagents.JSON.encode(nil) == "null"
  end

  test "encodes booleans" do
    assert CodexSubagents.JSON.encode(true) == "true"
    assert CodexSubagents.JSON.encode(false) == "false"
  end

  test "encodes integers" do
    assert CodexSubagents.JSON.encode(42) == "42"
    assert CodexSubagents.JSON.encode(0) == "0"
    assert CodexSubagents.JSON.encode(-7) == "-7"
  end

  test "encodes floats" do
    encoded = CodexSubagents.JSON.encode(3.14)
    assert is_binary(encoded)
    assert String.to_float(encoded) == 3.14
  end

  test "encodes atoms as strings" do
    assert CodexSubagents.JSON.encode(:succeeded) == "\"succeeded\""
    assert CodexSubagents.JSON.encode(:failed) == "\"failed\""
  end

  test "encodes empty containers" do
    assert CodexSubagents.JSON.encode(%{}) == "{}"
    assert CodexSubagents.JSON.encode([]) == "[]"
  end

  test "encodes nested structures" do
    data = %{items: [1, "two", true], nested: %{deep: nil}}
    encoded = CodexSubagents.JSON.encode(data)

    assert encoded ==
             "{\"items\":[1,\"two\",true],\"nested\":{\"deep\":null}}"
  end

  test "encodes DateTime as ISO 8601 string" do
    dt = ~U[2025-01-15 12:30:00Z]
    encoded = CodexSubagents.JSON.encode(dt)
    assert encoded == "\"2025-01-15T12:30:00Z\""
  end
end
