defmodule Pylixir.ExampleInferenceTest do
  use ExUnit.Case, async: true

  alias Pylixir.{Context, ExampleInference, TypeInfer}

  defp module_env(locals) do
    %{
      "events" => [
        %{"event" => "module_end", "scope" => "module", "lineno" => nil, "locals" => locals}
      ],
      "uncaught" => nil,
      "truncated" => false
    }
  end

  describe "seed/4" do
    test "no examples → ctx unchanged" do
      ctx = Context.new()
      assert ExampleInference.seed([], [], ctx, source: "x = 1\n") == ctx
    end

    test "examples with pre-supplied trace_events populate assume_types" do
      ctx = Context.new()
      env = module_env(%{"n" => "int", "xs" => %{"kind" => "list", "elems" => ["int"]}})

      result =
        ExampleInference.seed(
          [],
          [%{stdin: "ignored\n", stdout: "", trace_events: env}],
          ctx,
          source: nil
        )

      assert result.assume_types == %{
               module: %{"n" => {:int}, "xs" => {:list, {:int}}}
             }
    end

    test "examples without trace_events and without :source → skipped (no envelope)" do
      ctx = Context.new()
      result = ExampleInference.seed([], [%{stdin: "5\n"}], ctx, source: nil)
      assert result.assume_types == %{}
    end

    test "envelope with uncaught → ctx.assume_types_partial? = true" do
      ctx = Context.new()

      env =
        %{module_env(%{"n" => "int"}) | "uncaught" => %{"type" => "ValueError", "lineno" => 2}}

      result =
        ExampleInference.seed(
          [],
          [%{stdin: "x\n", stdout: "", trace_events: env}],
          ctx,
          source: nil
        )

      assert result.assume_types_partial? == true
    end

    test "all-successful envelopes → assume_types_partial? = false" do
      ctx = Context.new()
      env = module_env(%{"n" => "int"})

      result =
        ExampleInference.seed([], [%{stdin: "5\n", stdout: "", trace_events: env}], ctx,
          source: nil
        )

      assert result.assume_types_partial? == false
    end
  end

  describe "run_tracer/3 failure modes" do
    test "tracer crash on syntax error returns {:error, _}" do
      assert {:error, _} = ExampleInference.run_tracer("def )\n", "")
    end

    test "tracer timeout returns {:error, :timeout}" do
      # 1ms timeout will trigger before even Python boots.
      assert {:error, :timeout} =
               ExampleInference.run_tracer("import time\ntime.sleep(5)\n", "",
                 trace_timeout_ms: 1
               )
    end
  end

  describe "TypeInfer.bind/3 with assume_types (softened A′)" do
    setup do
      ctx = %{Context.new() | assume_types: %{module: %{"x" => {:int}}}, assume_types_scope: :module}
      {:ok, ctx: ctx}
    end

    test "weak syntactic + trace concrete → uses trace", %{ctx: ctx} do
      ctx2 = TypeInfer.bind(ctx, "x", :any)
      assert ctx2.types["x"] == {:int}
      assert ctx2.assume_types[:module]["x"] == {:int}
    end

    test "concrete syntactic matching trace → uses trace", %{ctx: ctx} do
      ctx2 = TypeInfer.bind(ctx, "x", {:int})
      assert ctx2.types["x"] == {:int}
    end

    test "concrete syntactic disagreeing → drops name from assume_types, binds syntactic", %{ctx: ctx} do
      ctx2 = TypeInfer.bind(ctx, "x", {:str})
      assert ctx2.types["x"] == {:str}
      refute Map.has_key?(ctx2.assume_types, :module) and
               Map.has_key?(ctx2.assume_types[:module] || %{}, "x")
    end

    test "name not in assume_types → normal bind", %{ctx: ctx} do
      ctx2 = TypeInfer.bind(ctx, "other", {:str})
      assert ctx2.types["other"] == {:str}
      assert ctx2.assume_types[:module]["x"] == {:int}
    end

    test "scope = nil → never consults assume_types" do
      ctx =
        %{Context.new() | assume_types: %{module: %{"x" => {:int}}}, assume_types_scope: nil}

      ctx2 = TypeInfer.bind(ctx, "x", :any)
      assert ctx2.types["x"] == :any
    end
  end

  describe "TypeInfer.demote/2 with assume_types (Q1)" do
    test "no-op for names in assume_types" do
      ctx = %{
        Context.new()
        | assume_types: %{module: %{"xs" => {:list, {:int}}}},
          assume_types_scope: :module,
          types: %{"xs" => {:list, {:int}}}
      }

      assert TypeInfer.demote(ctx, "xs") == ctx
    end

    test "normal demotion for names not in assume_types" do
      ctx = %{Context.new() | types: %{"xs" => {:list, {:int}}}}
      result = TypeInfer.demote(ctx, "xs")
      assert result.types["xs"] == {:list, :any}
    end
  end

  defp python_available? do
    python = System.get_env("PYLIXIR_PYTHON") || "python3.14"

    case System.cmd(python, ["--version"], stderr_to_stdout: true) do
      {out, 0} -> String.starts_with?(out, "Python 3.14")
      _ -> false
    end
  rescue
    ErlangError -> false
  end

  describe "boundary guards" do
    test "scalar guard emitted for n = int(input())" do
      if python_available?() do
        out =
          Pylixir.transpile("n = int(input())\nprint(n + 1)\n",
            examples: [%{stdin: "5\n", stdout: "6\n"}]
          )

        assert String.contains?(out, "Pylixir.BoundaryViolationError")
        assert String.contains?(out, "is_integer(v)")
        assert String.contains?(out, "expected: :int")
      end
    end

    test "no guard emitted when no examples supplied" do
      if python_available?() do
        out = Pylixir.transpile("n = int(input())\nprint(n + 1)\n")
        refute String.contains?(out, "BoundaryViolationError")
      end
    end
  end

  describe "end-to-end with examples" do
    test "indirect dispatch sample: examples eliminate py_add" do
      if python_available?() do
        src = """
        def parse(s):
            return int(s)

        funcs = {"parse": parse}
        n = funcs["parse"](input())
        print(n + 1)
        """

        without_examples = Pylixir.transpile(src)
        with_examples = Pylixir.transpile(src, examples: [%{stdin: "5\n", stdout: "6\n"}])

        assert String.contains?(without_examples, "py_add"),
               "baseline should still need py_add for the :any-typed n"

        refute String.contains?(with_examples, "py_add"),
               "with examples, n is typed as :int and arithmetic is native"
      end
    end
  end
end
