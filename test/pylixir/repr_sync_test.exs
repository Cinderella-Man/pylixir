defmodule Pylixir.ReprSyncTest do
  @moduledoc """
  Sync test: `Pylixir.LiteralFold.str_repr/1` (compile-time fold) and
  `Pylixir.RuntimeHelpers.py_repr/1` + `py_repr_str/1` (runtime) MUST
  produce byte-identical output for every input. The algorithms are
  duplicated by necessity — the runtime form gets spliced into
  standalone generated `.exs` files that don't have `Pylixir.LiteralFold`
  loaded — so this test stands guard against drift.
  """

  use ExUnit.Case, async: true

  alias Pylixir.LiteralFold
  alias Pylixir.RuntimeHelpers

  @corpus [
    "",
    "hello",
    "it's",
    ~s|say "hi"|,
    ~s|both 'a' and "b"|,
    "with\nnewline",
    "tab\there",
    "carriage\rreturn",
    "form\ffeed",
    "vertical\vtab",
    "back\bspace",
    "alarm\abell",
    <<0>>,
    <<0x7F>>,
    <<0x80::utf8>>,
    <<0x9F::utf8>>,
    "trailing backslash \\",
    "backslash\\nN",
    "mixed: \\ ' \" \n \t \r and \x01 control",
    "unicode α β γ printable",
    String.duplicate("x", 100)
  ]

  for {input, idx} <- Enum.with_index(@corpus) do
    test "py_repr / py_repr_str / LiteralFold.str_repr agree on corpus item ##{idx}" do
      input = unquote(input)

      from_fold = LiteralFold.str_repr(input)
      from_runtime = RuntimeHelpers.py_repr(input)
      from_repr_str = RuntimeHelpers.py_repr_str(input)

      assert from_fold == from_runtime,
             "LiteralFold.str_repr/1 diverged from RuntimeHelpers.py_repr/1 on input #{inspect(input)}"

      assert from_repr_str == from_runtime,
             "py_repr_str/1 diverged from py_repr/1 on input #{inspect(input)}"
    end
  end
end
