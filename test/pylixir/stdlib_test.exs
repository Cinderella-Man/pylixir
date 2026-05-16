defmodule Pylixir.StdlibTest do
  use ExUnit.Case, async: true

  alias Pylixir.Stdlib

  defp valid_lowering?({:ok, _}), do: true
  defp valid_lowering?({:error, hint}) when is_binary(hint), do: true
  defp valid_lowering?(:no_clause), do: true
  defp valid_lowering?(_), do: false

  describe "registry surface" do
    test "supported?/1 — math + sys ship by default, unknown names are out" do
      assert Stdlib.supported?("math")
      assert Stdlib.supported?("sys")
      refute Stdlib.supported?("os")
      refute Stdlib.supported?("json")
      refute Stdlib.supported?("")
    end

    test "impl/1 — returns the module for known names, nil otherwise" do
      assert Stdlib.impl("math") == Pylixir.Stdlib.Math
      assert Stdlib.impl("sys") == Pylixir.Stdlib.Sys
      assert Stdlib.impl("os") == nil
    end

    test "names/0 — sorted list of registered module names" do
      assert Stdlib.names() == ["bisect", "itertools", "math", "sys"]
    end
  end

  describe "behaviour contract — return shapes" do
    test "every registered impl returns a valid lowering tuple for attribute/2" do
      for mod_name <- Stdlib.names() do
        impl = Stdlib.impl(mod_name)

        for sample <- [["nonexistent_attr_xyz"], ["a", "b"]] do
          result = impl.attribute(sample, %{})

          assert valid_lowering?(result),
                 "#{mod_name}.attribute/2 returned unexpected shape for #{inspect(sample)}: #{inspect(result)}"
        end
      end
    end

    test "every registered impl returns a valid lowering tuple for call/4" do
      for mod_name <- Stdlib.names() do
        impl = Stdlib.impl(mod_name)
        result = impl.call(["nonexistent_call_xyz"], [], %{}, %{})

        assert valid_lowering?(result),
               "#{mod_name}.call/4 returned unexpected shape: #{inspect(result)}"
      end
    end
  end

  # Builtins isn't a Pylixir.Stdlib registry member (it's a single
  # hardcoded module for Python's implicit-global builtins), but it
  # shares Pylixir.Lowering's result type. Pin the contract here so a
  # future Builtins clause that forgot to wrap in {:ok, _} fails next
  # to its sibling.
  describe "behaviour contract — Builtins shares the result type" do
    alias Pylixir.Builtins

    test "every supported builtin name returns a valid lowering tuple when invoked" do
      # Probe each supported name with a generic 1-arg call. Clauses that
      # don't have a unary form return :no_clause — also valid.
      for name <- ~w(len abs range sorted reversed enumerate zip sum min max
                     map filter int float str bool list tuple set dict
                     isinstance print input chr ord hex oct bin round divmod
                     any all exit) do
        result = Builtins.emit(name, [{:x, [], nil}], %{})

        assert valid_lowering?(result),
               "Builtins.emit(#{inspect(name)}, [_], %{}) returned unexpected shape: " <>
                 inspect(result)
      end
    end

    test "unknown builtin name returns :no_clause" do
      assert Builtins.emit("not_a_builtin_xyz", [], %{}) == :no_clause
    end
  end
end
