defmodule Pylixir.Nodes.FunctionDefTest do
  use ExUnit.Case, async: true

  alias Pylixir.{Context, Converter, TranspileHelpers, UnsupportedNodeError}

  defp const(v), do: %{"_type" => "Constant", "value" => v}
  defp name(id), do: %{"_type" => "Name", "id" => id}
  defp op(n), do: %{"_type" => n}
  defp arg(id), do: %{"_type" => "arg", "arg" => id, "annotation" => nil}

  defp arguments(args, defaults \\ []),
    do: %{
      "_type" => "arguments",
      "posonlyargs" => [],
      "args" => args,
      "vararg" => nil,
      "kwonlyargs" => [],
      "kw_defaults" => [],
      "kwarg" => nil,
      "defaults" => defaults
    }

  defp function_def(fn_name, args, body, opts \\ []),
    do: %{
      "_type" => "FunctionDef",
      "name" => fn_name,
      "args" => args,
      "body" => body,
      "decorator_list" => Keyword.get(opts, :decorators, []),
      "returns" => nil,
      "type_params" => Keyword.get(opts, :type_params, [])
    }

  defp assign(target, value),
    do: %{"_type" => "Assign", "targets" => [target], "value" => value}

  defp call(func, args),
    do: %{"_type" => "Call", "func" => func, "args" => args, "keywords" => []}

  defp module_with(stmts), do: %{"_type" => "Module", "body" => stmts}

  describe "def_position guard" do
    test "at :module_top — emits a defp" do
      ctx = Context.new()

      {ast, _} =
        Converter.convert(
          function_def("greet", arguments([arg("name")]), [name("name")]),
          ctx
        )

      assert match?({:defp, [], [_, _]}, ast)
    end

    test "at :nested_fn — raises (T21 territory)" do
      ctx = %{Context.new() | def_position: :nested_fn}

      assert_raise UnsupportedNodeError, ~r/nested function/, fn ->
        Converter.convert(function_def("inner", arguments([]), []), ctx)
      end
    end

    test "at :other — raises with control-flow hint" do
      ctx = %{Context.new() | def_position: :other}

      assert_raise UnsupportedNodeError, ~r/control flow/, fn ->
        Converter.convert(function_def("foo", arguments([]), []), ctx)
      end
    end
  end

  describe "argument validation" do
    test "rejects varargs" do
      args = arguments([]) |> Map.put("vararg", arg("args"))

      assert_raise UnsupportedNodeError, ~r/varargs/, fn ->
        Converter.convert(function_def("f", args, []), Context.new())
      end
    end

    test "rejects kwargs" do
      args = arguments([]) |> Map.put("kwarg", arg("kw"))

      assert_raise UnsupportedNodeError, ~r/kwargs/, fn ->
        Converter.convert(function_def("f", args, []), Context.new())
      end
    end

    test "rejects keyword-only params" do
      args = arguments([]) |> Map.put("kwonlyargs", [arg("x")])

      assert_raise UnsupportedNodeError, ~r/keyword-only/, fn ->
        Converter.convert(function_def("f", args, []), Context.new())
      end
    end

    test "rejects positional-only params" do
      args = arguments([]) |> Map.put("posonlyargs", [arg("x")])

      assert_raise UnsupportedNodeError, ~r/positional-only/, fn ->
        Converter.convert(function_def("f", args, []), Context.new())
      end
    end

    test "rejects decorators" do
      assert_raise UnsupportedNodeError, ~r/decorators/, fn ->
        Converter.convert(
          function_def("f", arguments([]), [], decorators: [name("decorator")]),
          Context.new()
        )
      end
    end

    test "type_params silently ignored (PEP 695)" do
      assert {{:defp, _, _}, _} =
               Converter.convert(
                 function_def("f", arguments([]), [], type_params: [%{"_type" => "TypeVar", "name" => "T"}]),
                 Context.new()
               )
    end
  end

  describe "default arguments" do
    test "trailing default produces `\\\\` ast for that param" do
      args = arguments([arg("x"), arg("y")], [const(0)])

      {ast, _} = Converter.convert(function_def("f", args, [name("y")]), Context.new())

      {:defp, [], [{:f, [], params}, _]} = ast
      assert length(params) == 2
      # Last param has the default syntax {:\\, [], [ref, default_ast]}
      assert match?({:\\, [], [_, 0]}, List.last(params))
    end
  end

  describe "end-to-end" do
    test "module-level def with no args, called from py_main" do
      ast =
        module_with([
          function_def("answer", arguments([]), [const(42)]),
          call(name("answer"), [])
        ])

      {_, value, _, diagnostics} = TranspileHelpers.transpile_and_run(ast)
      assert value == 42
      assert diagnostics == []
    end

    test "def with two args, call site supplies both" do
      add =
        function_def("add", arguments([arg("a"), arg("b")]), [
          %{
            "_type" => "BinOp",
            "op" => op("Add"),
            "left" => name("a"),
            "right" => name("b")
          }
        ])

      ast =
        module_with([
          add,
          call(name("add"), [const(3), const(4)])
        ])

      {_, value, _, _} = TranspileHelpers.transpile_and_run(ast)
      assert value == 7
    end

    test "def with a default arg" do
      greet =
        function_def(
          "greet",
          arguments([arg("name"), arg("greeting")], [const("Hello")]),
          [
            %{
              "_type" => "BinOp",
              "op" => op("Add"),
              "left" => %{
                "_type" => "BinOp",
                "op" => op("Add"),
                "left" => name("greeting"),
                "right" => const(", ")
              },
              "right" => name("name")
            }
          ]
        )

      ast =
        module_with([
          greet,
          call(name("greet"), [const("World")])
        ])

      {_, value, _, _} = TranspileHelpers.transpile_and_run(ast)
      assert value == "Hello, World"
    end

    test "module-attribute reference from inside a def" do
      add_pi =
        function_def("add_pi", arguments([arg("x")]), [
          %{
            "_type" => "BinOp",
            "op" => op("Add"),
            "left" => name("x"),
            "right" => name("PI")
          }
        ])

      ast =
        module_with([
          assign(name("PI"), const(3.14)),
          add_pi,
          call(name("add_pi"), [const(1.0)])
        ])

      {_, value, _, _} = TranspileHelpers.transpile_and_run(ast)
      assert_in_delta value, 4.14, 1.0e-9
    end
  end
end
