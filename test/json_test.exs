defmodule SubagentSupervisor.JSONTest do
  use ExUnit.Case, async: true

  test "encodes maps and escaped strings" do
    assert SubagentSupervisor.JSON.encode(%{ok: true, output: "a\n\"b\""}) ==
             "{\"ok\":true,\"output\":\"a\\n\\\"b\\\"\"}"
  end

  test "encodes nil" do
    assert SubagentSupervisor.JSON.encode(nil) == "null"
  end

  test "encodes booleans" do
    assert SubagentSupervisor.JSON.encode(true) == "true"
    assert SubagentSupervisor.JSON.encode(false) == "false"
  end

  test "encodes integers" do
    assert SubagentSupervisor.JSON.encode(42) == "42"
    assert SubagentSupervisor.JSON.encode(0) == "0"
    assert SubagentSupervisor.JSON.encode(-7) == "-7"
  end

  test "encodes floats" do
    encoded = SubagentSupervisor.JSON.encode(3.14)
    assert is_binary(encoded)
    assert String.to_float(encoded) == 3.14
  end

  test "encodes atoms as strings" do
    assert SubagentSupervisor.JSON.encode(:succeeded) == "\"succeeded\""
    assert SubagentSupervisor.JSON.encode(:failed) == "\"failed\""
  end

  test "encodes empty containers" do
    assert SubagentSupervisor.JSON.encode(%{}) == "{}"
    assert SubagentSupervisor.JSON.encode([]) == "[]"
  end

  test "encodes nested structures" do
    data = %{items: [1, "two", true], nested: %{deep: nil}}
    encoded = SubagentSupervisor.JSON.encode(data)

    assert encoded ==
             "{\"items\":[1,\"two\",true],\"nested\":{\"deep\":null}}"
  end

  test "encodes DateTime as ISO 8601 string" do
    dt = ~U[2025-01-15 12:30:00Z]
    encoded = SubagentSupervisor.JSON.encode(dt)
    assert encoded == "\"2025-01-15T12:30:00Z\""
  end

  test "escapes backspace and form feed" do
    assert SubagentSupervisor.JSON.encode("a\b\fb") == "\"a\\b\\fb\""
  end

  test "escapes null and other control characters" do
    assert SubagentSupervisor.JSON.encode(<<"\x00\x01\x1F", "ok">>) ==
             "\"\\u0000\\u0001\\u001Fok\""
  end
end
