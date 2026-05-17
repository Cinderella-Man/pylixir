defmodule Pylixir.Nodes.LiteralsTest do
  use ExUnit.Case, async: true

  alias Pylixir.{Context, Converter, UnsupportedNodeError}

  defp const(v), do: %{"_type" => "Constant", "value" => v}
  defp name(id), do: %{"_type" => "Name", "id" => id}
  defp list_node(elts), do: %{"_type" => "List", "elts" => elts}
  defp tuple_node(elts), do: %{"_type" => "Tuple", "elts" => elts}
  defp dict_node(keys, values), do: %{"_type" => "Dict", "keys" => keys, "values" => values}

  describe "List literals" do
    test "empty list → []" do
      {ast, _} = Converter.convert(list_node([]), Context.new())
      assert ast == []
    end

    test "single element" do
      {ast, _} = Converter.convert(list_node([const(1)]), Context.new())
      assert ast == [1]
    end

    test "multiple element with mixed types" do
      {ast, _} = Converter.convert(list_node([const(1), const("a"), const(true)]), Context.new())
      assert ast == [1, "a", true]
    end

    test "nested list" do
      inner = list_node([const(1), const(2)])
      {ast, _} = Converter.convert(list_node([inner, const(3)]), Context.new())
      assert ast == [[1, 2], 3]
    end

    test "list of Name references threads through T07" do
      {ast, _} = Converter.convert(list_node([name("x"), name("y")]), Context.new())
      assert ast == [{:x, [], nil}, {:y, [], nil}]
    end
  end

  describe "Tuple literals — n-tuple AST shape" do
    test "empty tuple → {:{}, [], []}" do
      {ast, _} = Converter.convert(tuple_node([]), Context.new())
      assert ast == {:{}, [], []}
    end

    test "1-tuple → {:{}, [], [x]} (Elixir 1-tuple is a curly-brace literal)" do
      {ast, _} = Converter.convert(tuple_node([const(42)]), Context.new())
      assert ast == {:{}, [], [42]}
    end

    test "2-tuple → bare {a, b} Elixir literal (special-case shape)" do
      {ast, _} = Converter.convert(tuple_node([const(1), const(2)]), Context.new())
      assert ast == {1, 2}
    end

    test "3-tuple → {:{}, [], [a, b, c]}" do
      {ast, _} =
        Converter.convert(tuple_node([const(1), const(2), const(3)]), Context.new())

      assert ast == {:{}, [], [1, 2, 3]}
    end

    test "nested tuples" do
      inner = tuple_node([const(2), const(3)])
      {ast, _} = Converter.convert(tuple_node([const(1), inner]), Context.new())
      assert ast == {1, {2, 3}}
    end
  end

  describe "Dict literals" do
    test "empty dict → %{}" do
      {ast, _} = Converter.convert(dict_node([], []), Context.new())
      assert ast == {:%{}, [], []}
    end

    test "single pair" do
      {ast, _} = Converter.convert(dict_node([const("k")], [const(1)]), Context.new())
      assert ast == {:%{}, [], [{"k", 1}]}
    end

    test "multiple pairs in order" do
      {ast, _} =
        Converter.convert(
          dict_node([const("a"), const("b")], [const(1), const(2)]),
          Context.new()
        )

      assert ast == {:%{}, [], [{"a", 1}, {"b", 2}]}
    end

    test "nested dict value" do
      inner = dict_node([const("x")], [const(10)])
      {ast, _} = Converter.convert(dict_node([const("outer")], [inner]), Context.new())
      assert ast == {:%{}, [], [{"outer", {:%{}, [], [{"x", 10}]}}]}
    end

    test "mixed key types" do
      {ast, _} =
        Converter.convert(
          dict_node([const(1), const("two")], [const("one"), const(2)]),
          Context.new()
        )

      assert ast == {:%{}, [], [{1, "one"}, {"two", 2}]}
    end
  end

  describe "Starred elements are rejected (Q27 deviation from supported literals)" do
    test "Starred inside a List raises with a non-trivial hint" do
      starred = %{
        "_type" => "Starred",
        "value" => name("xs"),
        "lineno" => 4,
        "col_offset" => 1
      }

      err =
        assert_raise UnsupportedNodeError, fn ->
          Converter.convert(list_node([starred, const(3)]), Context.new())
        end

      assert err.node_type == "Starred"
      assert err.hint =~ "List"
      assert err.hint =~ "xs + ["
      assert err.lineno == 4
      assert err.col_offset == 1
    end

    test "Starred inside a Tuple raises" do
      starred = %{"_type" => "Starred", "value" => name("xs")}

      err =
        assert_raise UnsupportedNodeError, fn ->
          Converter.convert(tuple_node([const(1), starred]), Context.new())
        end

      assert err.node_type == "Starred"
      assert err.hint =~ "Tuple"
    end
  end

  describe "Dict-unpack ({**d}) lowers to Map.merge chain" do
    test "nil-key entry spreads the value into the literal via Map.merge" do
      node = dict_node([nil, const("k")], [name("d"), const(1)])
      node = Map.put(node, "lineno", 2)

      {ast, _} = Converter.convert(node, Context.new())
      rendered = Macro.to_string(ast)
      # Expect a Map.merge call combining the unpacked `d` with the
      # literal map containing `"k" => 1`.
      assert rendered =~ "Map.merge"
      assert rendered =~ "\"k\""
    end
  end

  describe "context threading" do
    test "literal containers don't disturb Context" do
      ctx = %{Context.new() | temp_counter: 5}

      {_, new_ctx} =
        Converter.convert(list_node([const(1), const(2), const(3)]), ctx)

      assert new_ctx.temp_counter == 5
    end
  end

  describe "end-to-end through Pylixir.to_source/1" do
    test "literal list as a module attribute roundtrips" do
      ast = %{
        "_type" => "Module",
        "body" => [
          %{
            "_type" => "Assign",
            "targets" => [name("COLORS")],
            "value" => list_node([const("red"), const("green")])
          }
        ]
      }

      output = Pylixir.to_source(ast)
      assert output =~ ~s(@var_COLORS ["red", "green"])
    end

    test "literal dict as a module attribute roundtrips" do
      ast = %{
        "_type" => "Module",
        "body" => [
          %{
            "_type" => "Assign",
            "targets" => [name("CONFIG")],
            "value" => dict_node([const("max")], [const(100)])
          }
        ]
      }

      output = Pylixir.to_source(ast)
      assert output =~ "@var_CONFIG"
      assert output =~ "\"max\" => 100"
    end
  end

  # f-strings lower to `<>` concats with each `FormattedValue` wrapped
  # in `py_str`. Format specs still raise (use `.format()` instead).
  describe "f-strings (JoinedStr)" do
    alias Pylixir.TranspileHelpers

    defp run(source) do
      python = System.get_env("PYLIXIR_PYTHON") || "python3.14"

      case System.cmd(python, ["--version"], stderr_to_stdout: true) do
        {out, 0} ->
          if String.starts_with?(out, "Python 3.14") do
            elixir_src = Pylixir.transpile(source)
            TranspileHelpers.run_source(elixir_src)
          else
            :skip
          end

        _ ->
          :skip
      end
    rescue
      ErlangError -> :skip
    end

    test "single interpolation" do
      case run("x = 42\nf\"value is {x}\"\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == "value is 42"
      end
    end

    test "multi-interpolation with mixed text" do
      case run("a = 1\nb = 2\nf\"{a} and {b}\"\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == "1 and 2"
      end
    end

    test "format spec is now lowered via py_format_value (no longer raises)" do
      python = System.get_env("PYLIXIR_PYTHON") || "python3.14"

      case System.cmd(python, ["--version"], stderr_to_stdout: true) do
        {out, 0} ->
          if String.starts_with?(out, "Python 3.14") do
            out_src = Pylixir.transpile("x = 3.14\nf\"{x:.2f}\"\n")
            assert out_src =~ "py_format_value"
          end

        _ ->
          :ok
      end
    end
  end
end
