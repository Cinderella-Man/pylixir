defmodule Pylixir.StdlibTest do
  use ExUnit.Case, async: true

  alias Pylixir.Stdlib

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
      assert Stdlib.names() == ["math", "sys"]
    end
  end

  describe "behaviour contract — return shapes" do
    defp valid_lowering?({:ok, _}), do: true
    defp valid_lowering?({:error, hint}) when is_binary(hint), do: true
    defp valid_lowering?(:no_clause), do: true
    defp valid_lowering?(_), do: false

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

    test "every registered impl returns a valid lowering tuple for call/3" do
      for mod_name <- Stdlib.names() do
        impl = Stdlib.impl(mod_name)
        result = impl.call(["nonexistent_call_xyz"], [], %{})

        assert valid_lowering?(result),
               "#{mod_name}.call/3 returned unexpected shape: #{inspect(result)}"
      end
    end
  end
end
