defmodule Pylixir.AppendBuildAnalysisTest do
  use ExUnit.Case, async: false

  alias Pylixir.AppendBuildAnalysis

  # --- AST builders ---------------------------------------------------

  defp const(value), do: %{"_type" => "Constant", "value" => value}
  defp name(id), do: %{"_type" => "Name", "id" => id}

  defp empty_list_bind(target_id),
    do: %{
      "_type" => "Assign",
      "targets" => [name(target_id)],
      "value" => %{"_type" => "List", "elts" => []}
    }

  defp call(func, args, keywords \\ []),
    do: %{"_type" => "Call", "func" => func, "args" => args, "keywords" => keywords}

  defp method_call(recv_id, method, args, keywords \\ []),
    do: %{
      "_type" => "Expr",
      "value" =>
        call(
          %{"_type" => "Attribute", "value" => name(recv_id), "attr" => method},
          args,
          keywords
        )
    }

  defp subscript_read(target_id, idx_value),
    do: %{"_type" => "Subscript", "value" => name(target_id), "slice" => const(idx_value)}

  defp expr(value), do: %{"_type" => "Expr", "value" => value}

  defp for_stmt(target_id, iter, body),
    do: %{
      "_type" => "For",
      "target" => name(target_id),
      "iter" => iter,
      "body" => body,
      "orelse" => []
    }

  defp assign(target_id, value),
    do: %{"_type" => "Assign", "targets" => [name(target_id)], "value" => value}

  defp call_name(fname, args, kw \\ []), do: call(name(fname), args, kw)

  defp aug_assign(target_id, op_value),
    do: %{"_type" => "AugAssign", "target" => name(target_id), "value" => op_value}

  # --- Happy path -----------------------------------------------------

  describe "happy path" do
    test "xs = []; for in src: xs.append(v); xs[i] later → frozen at the for-loop" do
      body = [
        empty_list_bind("xs"),
        for_stmt("v", name("src"), [method_call("xs", "append", [name("v")])]),
        expr(subscript_read("xs", 0))
      ]

      {names, freeze_after} = AppendBuildAnalysis.analyze(body)
      assert names == MapSet.new(["xs"])
      assert freeze_after == %{1 => MapSet.new(["xs"])}
    end

    test "two independent append-build candidates freeze at their own indices" do
      body = [
        empty_list_bind("xs"),
        for_stmt("v", name("src1"), [method_call("xs", "append", [name("v")])]),
        empty_list_bind("ys"),
        for_stmt("w", name("src2"), [method_call("ys", "append", [name("w")])]),
        expr(subscript_read("xs", 0)),
        expr(subscript_read("ys", 0))
      ]

      {names, freeze_after} = AppendBuildAnalysis.analyze(body)
      assert names == MapSet.new(["xs", "ys"])
      assert freeze_after == %{1 => MapSet.new(["xs"]), 3 => MapSet.new(["ys"])}
    end

    test "no reads after build still freezes (last mutation index)" do
      body = [
        empty_list_bind("xs"),
        for_stmt("v", name("src"), [method_call("xs", "append", [name("v")])])
      ]

      {names, freeze_after} = AppendBuildAnalysis.analyze(body)
      assert names == MapSet.new(["xs"])
      assert freeze_after == %{1 => MapSet.new(["xs"])}
    end

    test "len(xs) and `for v in xs` and `v in xs` are read-only uses" do
      body = [
        empty_list_bind("xs"),
        method_call("xs", "append", [const(1)]),
        expr(call_name("len", [name("xs")])),
        for_stmt("v", name("xs"), []),
        expr(%{
          "_type" => "Compare",
          "left" => const(1),
          "ops" => [%{"_type" => "In"}],
          "comparators" => [name("xs")]
        })
      ]

      {names, freeze_after} = AppendBuildAnalysis.analyze(body)
      assert names == MapSet.new(["xs"])
      assert freeze_after == %{1 => MapSet.new(["xs"])}
    end
  end

  # --- Bail cases -----------------------------------------------------

  describe "bails" do
    test "no .append calls → not a candidate (no_appends)" do
      body = [
        empty_list_bind("xs"),
        expr(subscript_read("xs", 0))
      ]

      assert {MapSet.new(), %{}} == AppendBuildAnalysis.analyze(body)
    end

    test "interleaved read between two appends → bail" do
      body = [
        empty_list_bind("xs"),
        method_call("xs", "append", [const(1)]),
        expr(subscript_read("xs", 0)),
        method_call("xs", "append", [const(2)])
      ]

      assert {MapSet.new(), %{}} == AppendBuildAnalysis.analyze(body)
    end

    test "reassignment after empty bind → bail" do
      body = [
        empty_list_bind("xs"),
        assign("xs", const(5)),
        method_call("xs", "append", [const(1)])
      ]

      assert {MapSet.new(), %{}} == AppendBuildAnalysis.analyze(body)
    end

    test "other mutation method (.pop) → leak/bail" do
      body = [
        empty_list_bind("xs"),
        method_call("xs", "append", [const(1)]),
        method_call("xs", "pop", [])
      ]

      assert {MapSet.new(), %{}} == AppendBuildAnalysis.analyze(body)
    end

    test "subscript assignment xs[i] = v → bail" do
      body = [
        empty_list_bind("xs"),
        method_call("xs", "append", [const(0)]),
        %{
          "_type" => "Assign",
          "targets" => [
            %{"_type" => "Subscript", "value" => name("xs"), "slice" => const(0)}
          ],
          "value" => const(1)
        }
      ]

      assert {MapSet.new(), %{}} == AppendBuildAnalysis.analyze(body)
    end

    test "AugAssign xs += [...] → bail" do
      body = [
        empty_list_bind("xs"),
        method_call("xs", "append", [const(1)]),
        aug_assign("xs", %{"_type" => "List", "elts" => [const(2)]})
      ]

      assert {MapSet.new(), %{}} == AppendBuildAnalysis.analyze(body)
    end

    test "alias `y = xs` leaks → bail" do
      body = [
        empty_list_bind("xs"),
        method_call("xs", "append", [const(1)]),
        assign("y", name("xs"))
      ]

      assert {MapSet.new(), %{}} == AppendBuildAnalysis.analyze(body)
    end

    test "non-empty list literal bind is not a candidate" do
      body = [
        assign("xs", %{"_type" => "List", "elts" => [const(1)]}),
        method_call("xs", "append", [const(2)])
      ]

      assert {MapSet.new(), %{}} == AppendBuildAnalysis.analyze(body)
    end

    test "second empty-list bind disqualifies (treated as reassignment)" do
      body = [
        empty_list_bind("xs"),
        method_call("xs", "append", [const(1)]),
        empty_list_bind("xs"),
        method_call("xs", "append", [const(2)])
      ]

      assert {MapSet.new(), %{}} == AppendBuildAnalysis.analyze(body)
    end

    test "PYLIXIR_DISABLE_ALIST=1 returns empty result" do
      body = [
        empty_list_bind("xs"),
        method_call("xs", "append", [const(1)])
      ]

      System.put_env("PYLIXIR_DISABLE_ALIST", "1")

      try do
        assert {MapSet.new(), %{}} == AppendBuildAnalysis.analyze(body)
      after
        System.delete_env("PYLIXIR_DISABLE_ALIST")
      end
    end
  end

  # --- Sample-001-flavoured end-to-end pattern ------------------------

  describe "sample 001 shape" do
    test "two cumulative-sum builds followed by a read loop" do
      # Mirrors x_sums = []; for n in x: x_sums.append(...) etc.
      body = [
        empty_list_bind("x_sums"),
        assign("current", const(0)),
        for_stmt("n", name("x"), [
          aug_assign("current", name("n")),
          method_call("x_sums", "append", [name("current")])
        ]),
        empty_list_bind("y_sums"),
        assign("current", const(0)),
        for_stmt("n", name("y"), [
          aug_assign("current", name("n")),
          method_call("y_sums", "append", [name("current")])
        ]),
        expr(call_name("len", [name("x_sums")])),
        expr(call_name("len", [name("y_sums")]))
      ]

      {names, freeze_after} = AppendBuildAnalysis.analyze(body)
      assert names == MapSet.new(["x_sums", "y_sums"])
      # x_sums frozen after stmt 2 (its for-loop), y_sums after stmt 5.
      assert freeze_after == %{
               2 => MapSet.new(["x_sums"]),
               5 => MapSet.new(["y_sums"])
             }
    end
  end
end
