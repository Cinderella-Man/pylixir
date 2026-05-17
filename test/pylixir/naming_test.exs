defmodule Pylixir.NamingTest do
  use ExUnit.Case, async: true

  alias Pylixir.Naming

  describe "reserved?/1 — Category 1: hard keywords" do
    test "Elixir hard keywords that the parser rejects as var names" do
      for kw <- ~w(true false nil when and or not in fn do end catch rescue after else) do
        assert Naming.reserved?(kw), "expected #{inspect(kw)} to be reserved (hard keyword)"
      end
    end
  end

  describe "reserved?/1 — Category 2: special forms" do
    test "Elixir special forms that would shadow generated control flow" do
      for sf <- ~w(if unless case cond for receive try with quote unquote super) do
        assert Naming.reserved?(sf), "expected #{inspect(sf)} to be reserved (special form)"
      end
    end

    test "Elixir source-location dunders" do
      assert Naming.reserved?("__MODULE__")
      assert Naming.reserved?("__DIR__")
      assert Naming.reserved?("__ENV__")
    end
  end

  describe "reserved?/1 — Category 3: Kernel auto-imports" do
    test "common Kernel functions/macros that real Python code routinely binds" do
      # The most likely collisions in real Python code.
      for kernel <- ~w(length hd tl div rem abs max min round trunc apply send spawn) do
        assert Naming.reserved?(kernel), "expected #{kernel} to be reserved (Kernel)"
      end
    end

    test "is_* Kernel guards" do
      assert Naming.reserved?("is_integer")
      assert Naming.reserved?("is_list")
      assert Naming.reserved?("is_map")
    end
  end

  describe "reserved?/1 — Category 4: alias-shaped (ASCII uppercase first)" do
    test "single-letter uppercase names that the Elixir parser treats as aliases" do
      for id <- ~w(W H I A Z) do
        assert Naming.reserved?(id), "expected #{inspect(id)} to be reserved (alias-shaped)"
      end
    end

    test "longer uppercase-leading names — Python-idiomatic constants and locals" do
      for id <- ~w(PI COLORS CONFIG MaxRetries CamelCase) do
        assert Naming.reserved?(id), "expected #{inspect(id)} to be reserved (alias-shaped)"
      end
    end
  end

  describe "reserved?/1 — non-reserved" do
    test "plain user identifiers are not reserved" do
      refute Naming.reserved?("foo")
      refute Naming.reserved?("my_variable")
      refute Naming.reserved?("counter")
      refute Naming.reserved?("x")
    end

    test "leading underscore is not alias-shaped (Elixir treats _Foo as a variable)" do
      refute Naming.reserved?("_W")
      refute Naming.reserved?("_private")
    end
  end

  describe "reserved_prefix?/1 — Pylixir's own namespace" do
    test "py_* identifiers remain reserved (runtime-helper namespace)" do
      assert Naming.reserved_prefix?("py_foo")
      assert Naming.reserved_prefix?("py_")
    end

    test "var_* identifiers are no longer reserved — rewritten with usr_ prefix" do
      # `var_type` is legal Python; we now emit `usr_var_type` to avoid
      # colliding with Python `type` → `var_type`.
      refute Naming.reserved_prefix?("var_type")
      assert Naming.rewrite("var_type") == "usr_var_type"
      assert Naming.rewrite("var_anything") == "usr_var_anything"
    end

    test "py_* identifiers are reserved (helper/wrapper collision)" do
      assert Naming.reserved_prefix?("py_add")
      assert Naming.reserved_prefix?("py_main")
      assert Naming.reserved_prefix?("py_")
    end

    test "plain identifiers do not match the reserved prefix" do
      refute Naming.reserved_prefix?("var")
      refute Naming.reserved_prefix?("py")
      refute Naming.reserved_prefix?("vary")
      refute Naming.reserved_prefix?("python")
      refute Naming.reserved_prefix?("foo")
    end
  end

  describe "rewrite/1" do
    test "reserved names get the var_ prefix" do
      assert Naming.rewrite("if") == "var_if"
      assert Naming.rewrite("length") == "var_length"
      assert Naming.rewrite("when") == "var_when"
    end

    test "alias-shaped names get the var_ prefix" do
      assert Naming.rewrite("W") == "var_W"
      assert Naming.rewrite("PI") == "var_PI"
      assert Naming.rewrite("MaxRetries") == "var_MaxRetries"
    end

    test "plain names pass through unchanged" do
      assert Naming.rewrite("foo") == "foo"
      assert Naming.rewrite("my_counter") == "my_counter"
      assert Naming.rewrite("_W") == "_W"
    end
  end
end
