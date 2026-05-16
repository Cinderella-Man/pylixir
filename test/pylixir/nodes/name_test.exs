defmodule Pylixir.Nodes.NameTest do
  use ExUnit.Case, async: true

  alias Pylixir.{Context, Converter, UnsupportedNodeError}

  defp name(id, extra \\ %{}), do: Map.merge(%{"_type" => "Name", "id" => id}, extra)

  describe "plain identifiers" do
    test "passes through as a bare Elixir var-reference triple" do
      {ast, ctx} = Converter.convert(name("foo"), Context.new())
      assert ast == {:foo, [], nil}
      assert ctx == Context.new()
    end

    test "snake_case unchanged" do
      {ast, _} = Converter.convert(name("counter_value"), Context.new())
      assert ast == {:counter_value, [], nil}
    end
  end

  describe "reserved name rewriting (Naming categories 1–3)" do
    test "hard Elixir keyword `if` rewrites to var_if" do
      {ast, _} = Converter.convert(name("if"), Context.new())
      assert ast == {:var_if, [], nil}
    end

    test "hard Elixir keyword `end` rewrites to var_end" do
      {ast, _} = Converter.convert(name("end"), Context.new())
      assert ast == {:var_end, [], nil}
    end

    test "special form `case` rewrites to var_case" do
      {ast, _} = Converter.convert(name("case"), Context.new())
      assert ast == {:var_case, [], nil}
    end

    test "Kernel auto-import `length` rewrites to var_length" do
      {ast, _} = Converter.convert(name("length"), Context.new())
      assert ast == {:var_length, [], nil}
    end

    test "Kernel guard `is_integer` rewrites to var_is_integer" do
      {ast, _} = Converter.convert(name("is_integer"), Context.new())
      assert ast == {:var_is_integer, [], nil}
    end
  end

  describe "module-attribute reference (T05 partition + T07 emission)" do
    test "id in Context.module_attrs emits @var_<id>" do
      ctx = %{Context.new() | module_attrs: MapSet.new(["PI"])}
      {ast, _} = Converter.convert(name("PI"), ctx)

      assert ast == {:@, [], [{:var_PI, [], nil}]}
    end

    test "non-module-attr uppercase names get the var_ rewrite (alias-shape collision)" do
      # `PI` is a module attr in some other module; here it's a plain local.
      # Bare emission of `:PI` would render as the Elixir alias `PI`, not a
      # variable — so Naming's alias-shape rule rewrites it to `var_PI`.
      {ast, _} = Converter.convert(name("PI"), Context.new())
      assert ast == {:var_PI, [], nil}
    end

    test "a reserved name in module_attrs still emits @var_<id> (the var_ prefix is uniform)" do
      ctx = %{Context.new() | module_attrs: MapSet.new(["if"])}
      {ast, _} = Converter.convert(name("if"), ctx)

      assert ast == {:@, [], [{:var_if, [], nil}]}
    end
  end

  describe "__name__ special case" do
    test "emits the literal string \"__main__\" — the script-entry idiom" do
      {ast, _} = Converter.convert(name("__name__"), Context.new())
      assert ast == "__main__"
    end

    test "the substitution wins over the reserved-name rewrite path" do
      # `__name__` is not in any Naming category, but even if it were, the
      # __name__ special case is checked first.
      {ast, _} = Converter.convert(name("__name__"), Context.new())
      refute is_tuple(ast)
    end
  end

  describe "reserved-prefix rejection (inverse-collision protection)" do
    test "Python identifier `var_foo` raises with a helpful hint" do
      err =
        assert_raise UnsupportedNodeError, fn ->
          Converter.convert(
            name("var_foo", %{"lineno" => 5, "col_offset" => 2}),
            Context.new()
          )
        end

      assert err.node_type == "Name"
      assert err.hint =~ "var_foo"
      assert err.hint =~ "reserved"
      assert err.lineno == 5
      assert err.col_offset == 2
    end

    test "Python identifier `py_add` raises" do
      err =
        assert_raise UnsupportedNodeError, fn ->
          Converter.convert(name("py_add"), Context.new())
        end

      assert err.node_type == "Name"
      assert err.hint =~ "py_add"
    end

    test "the rejection fires regardless of whether the name is also in module_attrs" do
      # Defence-in-depth: even if a faulty Pass 1 promoted a reserved-
      # prefix name, T07 still refuses to emit it.
      ctx = %{Context.new() | module_attrs: MapSet.new(["py_thing"])}

      assert_raise UnsupportedNodeError, fn ->
        Converter.convert(name("py_thing"), ctx)
      end
    end
  end

  describe "end-to-end integration via to_source/1" do
    test "PI = 3.14 + reference flows through the wrapper" do
      ast = %{
        "_type" => "Module",
        "body" => [
          %{
            "_type" => "Assign",
            "targets" => [name("PI")],
            "value" => %{"_type" => "Constant", "value" => 3.14}
          }
        ]
      }

      output = Pylixir.to_source(ast)
      assert output =~ "@var_PI"
    end
  end
end
