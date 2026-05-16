defmodule Eval.BucketTest do
  use ExUnit.Case, async: true

  alias Eval.Bucket

  @sample %{id: "0", source: "x = 1"}

  test "classifies UnsupportedNodeError by node_type" do
    exception = %Pylixir.UnsupportedNodeError{
      node_type: "ClassDef",
      hint: "classes not supported",
      lineno: 3,
      col_offset: 0,
      message: "ClassDef at line 3, col 0: classes not supported"
    }

    assert {{:unsupported, "ClassDef"}, meta} =
             Bucket.classify(@sample, {:transpile_raised, exception})

    assert meta.node_type == "ClassDef"
    assert meta.hint == "classes not supported"
    assert meta.lineno == 3
  end

  test "classifies PythonParseError as :parse_error" do
    exception = %Pylixir.PythonParseError{
      message: "invalid syntax",
      lineno: 1,
      col_offset: 0,
      text: "def "
    }

    assert {:parse_error, meta} = Bucket.classify(@sample, {:transpile_raised, exception})
    assert meta.message == "invalid syntax"
  end

  test "classifies clean compile as :ok ignoring stylistic warnings" do
    diag = %{message: "variable foo is unused", severity: :warning}

    assert {:ok, _} =
             Bucket.classify(@sample, {:transpile_ok, "src", {:compile_ok, [diag]}})
  end

  test "classifies real compile diagnostic as {:compile_error, fingerprint}" do
    diag = %{
      message: "undefined function py_missing/0",
      severity: :error,
      position: 10
    }

    assert {{:compile_error, fingerprint}, meta} =
             Bucket.classify(@sample, {:transpile_ok, "src", {:compile_ok, [diag]}})

    assert is_binary(fingerprint)
    assert fingerprint =~ "undefined function"
    assert meta.diagnostic.message =~ "py_missing"
  end

  test "slug/1 produces filesystem-safe strings" do
    assert Bucket.slug({:unsupported, "ClassDef"}) == "unsupported--ClassDef"
    assert Bucket.slug(:parse_error) == "parse_error"
    assert Bucket.slug({:compile_error, "weird /msg with spaces"}) =~ "compile_error--"
  end
end
