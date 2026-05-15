defmodule Pylixir.Nodes.ReturnTest do
  use ExUnit.Case, async: true

  alias Pylixir.{Context, Converter, TranspileHelpers, UnsupportedNodeError}

  defp const(v), do: %{"_type" => "Constant", "value" => v}
  defp name(id), do: %{"_type" => "Name", "id" => id}
  defp op(n), do: %{"_type" => n}
  defp arg(id), do: %{"_type" => "arg", "arg" => id}

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

  defp function_def(fn_name, args, body),
    do: %{
      "_type" => "FunctionDef",
      "name" => fn_name,
      "args" => args,
      "body" => body,
      "decorator_list" => [],
      "returns" => nil,
      "type_params" => []
    }

  defp return_node(value), do: %{"_type" => "Return", "value" => value}

  defp compare(left, op_name, right),
    do: %{"_type" => "Compare", "left" => left, "ops" => [op(op_name)], "comparators" => [right]}

  defp if_node(test, body, orelse \\ []),
    do: %{"_type" => "If", "test" => test, "body" => body, "orelse" => orelse}

  defp call(func, args),
    do: %{"_type" => "Call", "func" => func, "args" => args, "keywords" => []}

  defp module_with(stmts), do: %{"_type" => "Module", "body" => stmts}

  describe "Return outside a function" do
    test "raises with a SyntaxError-style hint" do
      assert_raise UnsupportedNodeError, ~r/return/i, fn ->
        Converter.convert(return_node(const(1)), Context.new())
      end
    end
  end

  describe "wrap decision — :unwrapped (single tail Return)" do
    test "def f(): return 1 — body is just the value, no try/catch" do
      ast =
        module_with([
          function_def("f", arguments([]), [return_node(const(1))]),
          call(name("f"), [])
        ])

      {source, value, _, _} = TranspileHelpers.transpile_and_run(ast)
      assert value == 1
      refute source =~ "throw"
      refute source =~ ":pylixir_return"
    end

    test "def f(x): return x — argument passes through" do
      ast =
        module_with([
          function_def("f", arguments([arg("x")]), [return_node(name("x"))]),
          call(name("f"), [const(42)])
        ])

      {_, value, _, _} = TranspileHelpers.transpile_and_run(ast)
      assert value == 42
    end
  end

  describe "wrap decision — :wrapped (multiple Returns OR non-tail Return)" do
    test "def f(): if x: return 1; return 2 — Return inside if + tail Return → wrapped" do
      ast =
        module_with([
          function_def(
            "f",
            arguments([arg("x")]),
            [
              if_node(compare(name("x"), "Gt", const(0)), [return_node(const(1))]),
              return_node(const(2))
            ]
          ),
          call(name("f"), [const(5)])
        ])

      {source, value, _, _} = TranspileHelpers.transpile_and_run(ast)
      assert value == 1
      assert source =~ ":pylixir_return"
    end

    test "the same function with x=-1 takes the fall-through branch" do
      ast =
        module_with([
          function_def(
            "f",
            arguments([arg("x")]),
            [
              if_node(compare(name("x"), "Gt", const(0)), [return_node(const(1))]),
              return_node(const(2))
            ]
          ),
          call(name("f"), [const(-1)])
        ])

      {_, value, _, _} = TranspileHelpers.transpile_and_run(ast)
      assert value == 2
    end

    test "bare `return` (Return with value=None) inside wrapped body returns nil" do
      ast =
        module_with([
          function_def(
            "f",
            arguments([arg("x")]),
            [
              if_node(compare(name("x"), "Gt", const(0)), [return_node(nil)]),
              return_node(const(42))
            ]
          ),
          call(name("f"), [const(1)])
        ])

      {_, value, _, _} = TranspileHelpers.transpile_and_run(ast)
      assert value == nil
    end
  end

  describe "regression guards" do
    test "single non-tail Return (no other statements after) still wraps because it's inside If" do
      # def f(x): if x: return 1  — only one Return, but it's inside an If.
      ast =
        module_with([
          function_def(
            "f",
            arguments([arg("x")]),
            [
              if_node(compare(name("x"), "Gt", const(0)), [return_node(const(1))])
            ]
          ),
          call(name("f"), [const(5)])
        ])

      {source, value, _, _} = TranspileHelpers.transpile_and_run(ast)
      assert value == 1
      assert source =~ ":pylixir_return"
    end

    test "def f(x): if x: return 1 — falsy branch returns nil (the if's nil-fallthrough)" do
      ast =
        module_with([
          function_def(
            "f",
            arguments([arg("x")]),
            [if_node(compare(name("x"), "Gt", const(0)), [return_node(const(1))])]
          ),
          call(name("f"), [const(-1)])
        ])

      {_, value, _, _} = TranspileHelpers.transpile_and_run(ast)
      assert value == nil
    end
  end
end
