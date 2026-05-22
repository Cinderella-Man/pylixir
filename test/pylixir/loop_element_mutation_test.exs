defmodule Pylixir.LoopElementMutationTest do
  # async: false — the T4 cases toggle the `enable_t4_break_continue`
  # application env, and `run_source/1` compiles modules globally.
  use ExUnit.Case, async: false

  alias Pylixir.TranspileHelpers

  defp python_cmd, do: System.get_env("PYLIXIR_PYTHON") || "python3.14"

  defp python_available? do
    case System.cmd(python_cmd(), ["--version"], stderr_to_stdout: true) do
      {out, 0} -> String.starts_with?(out, "Python 3.14")
      _ -> false
    end
  rescue
    ErlangError -> false
  end

  # Transpile + compile + run; assert no compile *errors* and that stdout
  # matches the expected CPython output. Returns the Elixir source so the
  # caller can pin codegen shape.
  defp run!(src, expected_stdout) do
    elixir_src = Pylixir.transpile(src)
    {_, _value, stdout, diagnostics} = TranspileHelpers.run_source(elixir_src)
    errors = Enum.filter(diagnostics, &(&1[:severity] == :error))
    assert errors == [], "compile errors: " <> inspect(errors)
    assert stdout == expected_stdout, "stdout mismatch"
    elixir_src
  end

  describe "T1 — single bare-Name target, Enum.map rebuild" do
    @describetag :loop_mutation
    test "subscript / aug / method / nested-for / conditional mutations" do
      if python_available?() do
        src = run!("grid=[[1,2],[3,4]]\nfor row in grid:\n    row[0]=9\nprint(grid)\n", "[[9, 2], [9, 4]]\n")
        assert src =~ "Enum.map("
        refute src =~ "@var_grid"

        run!("grid=[[1,2],[3,4]]\nfor row in grid:\n    row[1]+=10\nprint(grid)\n", "[[1, 12], [3, 14]]\n")
        run!("grid=[[1],[2]]\nfor row in grid:\n    row.append(0)\nprint(grid)\n", "[[1, 0], [2, 0]]\n")

        run!(
          "grid=[[1,2],[3,4]]\nfor row in grid:\n    for j in range(len(row)):\n        row[j]*=2\nprint(grid)\n",
          "[[2, 4], [6, 8]]\n"
        )

        # Mutation nested inside an `if` is captured by the yield.
        run!(
          "grid=[[1,2],[3,4]]\nfor row in grid:\n    if row[0]==1:\n        row[1]=99\nprint(grid)\n",
          "[[1, 99], [3, 4]]\n"
        )
      end
    end

    test "fallback: wholesale rebind of target is unchanged (Enum.each)" do
      if python_available?() do
        src = run!("grid=[[1,2],[3,4]]\nfor row in grid:\n    row=[0,0]\nprint(grid)\n", "[[1, 2], [3, 4]]\n")
        assert src =~ "Enum.each("
        refute src =~ "Enum.map("
      end
    end
  end

  describe "Trap-guards (named, required)" do
    @describetag :loop_mutation
    test "read-after-mutation: de-promotion kills the stale-literal fold" do
      if python_available?() do
        # `print(grid)` must read the rebuilt runtime value, not a folded
        # literal — proves both the loop rebind AND the LiteralPropagation /
        # ModuleAnalysis de-promotion.
        src = run!("grid=[[1,2],[3,4]]\nfor row in grid:\n    row[0]=9\nprint(grid)\n", "[[9, 2], [9, 4]]\n")
        refute src =~ ~s("[[9, 2], [9, 4]]")
      end
    end

    test "int += no-op: must NOT rebuild" do
      if python_available?() do
        src = run!("nums=[1,2,3]\nfor x in nums:\n    x+=1\nprint(nums)\n", "[1, 2, 3]\n")
        refute src =~ "Enum.map("
      end
    end

    test "mutable list += rebuilds; += then wholesale falls back" do
      if python_available?() do
        run!("grid=[[1],[2]]\nfor row in grid:\n    row+=[9]\nprint(grid)\n", "[[1, 9], [2, 9]]\n")
        # `+=` then wholesale rebind ⇒ co-occurrence ⇒ fallback (grid unchanged).
        run!(
          "grid=[[1],[2]]\nfor row in grid:\n    row+=[9]\n    row=[]\nprint(grid)\n",
          "[[1], [2]]\n"
        )
      end
    end
  end

  describe "T2 — flat tuple targets" do
    @describetag :loop_mutation
    test "method/subscript mutation of a component rebuilds the element" do
      if python_available?() do
        run!(
          "pairs=[[[1],10],[[2],20]]\nfor a,b in pairs:\n    a.append(b)\nprint(pairs)\n",
          "[[[1, 10], 10], [[2, 20], 20]]\n"
        )

        run!(
          "pairs=[[[0],9],[[0],8]]\nfor a,b in pairs:\n    a[0]=b\nprint(pairs)\n",
          "[[[9], 9], [[8], 8]]\n"
        )
      end
    end

    test "fallback: a wholesale-rebound component leaves source unchanged" do
      if python_available?() do
        run!("pairs=[[1,2],[3,4]]\nfor a,b in pairs:\n    a=99\nprint(pairs)\n", "[[1, 2], [3, 4]]\n")
      end
    end
  end

  describe "T3 — threaded vars via Enum.map_reduce" do
    @describetag :loop_mutation
    test "rebuilds the source AND threads the accumulator(s)" do
      if python_available?() do
        src =
          run!(
            "grid=[[1,2],[3,4]]\ntotal=0\nfor row in grid:\n    row[0]=9\n    total+=row[1]\nprint(grid)\nprint(total)\n",
            "[[9, 2], [9, 4]]\n6\n"
          )

        assert src =~ "Enum.map_reduce("

        run!(
          "grid=[[1,2],[3,4]]\ns=0\nc=0\nfor row in grid:\n    row[0]=9\n    s+=row[1]\n    c+=1\nprint(grid)\nprint(s)\nprint(c)\n",
          "[[9, 2], [9, 4]]\n6\n2\n"
        )

        # T2 + T3: tuple target with an accumulator.
        run!(
          "pairs=[[[1],10],[[2],20]]\nacc=0\nfor a,b in pairs:\n    a.append(b)\n    acc+=b\nprint(pairs)\nprint(acc)\n",
          "[[[1, 10], 10], [[2, 20], 20]]\n30\n"
        )
      end
    end
  end

  describe "T4 — break/continue (gated; enabled here)" do
    @describetag :loop_mutation
    setup do
      Application.put_env(:pylixir, :enable_t4_break_continue, true)
      on_exit(fn -> Application.delete_env(:pylixir, :enable_t4_break_continue) end)
      :ok
    end

    test "break leaves the post-break tail untouched" do
      if python_available?() do
        src =
          run!(
            "grid=[[1,2],[3,4],[5,6]]\nfor row in grid:\n    row[0]=9\n    if row[1]==4:\n        break\nprint(grid)\n",
            "[[9, 2], [9, 4], [5, 6]]\n"
          )

        assert src =~ "reduce_while"
      end
    end

    test "break before the mutation leaves the break row unchanged" do
      if python_available?() do
        run!(
          "grid=[[1,2],[3,4],[5,6]]\nfor row in grid:\n    if row[1]==4:\n        break\n    row[0]=9\nprint(grid)\n",
          "[[9, 2], [3, 4], [5, 6]]\n"
        )
      end
    end

    test "continue keeps mutations up to the continue" do
      if python_available?() do
        run!(
          "grid=[[1,2],[3,4],[5,6]]\nfor row in grid:\n    if row[1]==4:\n        continue\n    row[0]=9\nprint(grid)\n",
          "[[9, 2], [3, 4], [9, 6]]\n"
        )
      end
    end

    test "threaded var carried correctly across a break" do
      if python_available?() do
        run!(
          "grid=[[1,2],[3,4],[5,6]]\ntot=0\nfor row in grid:\n    row[0]=9\n    tot+=row[1]\n    if row[1]==4:\n        break\nprint(grid)\nprint(tot)\n",
          "[[9, 2], [9, 4], [5, 6]]\n6\n"
        )
      end
    end

    test "gated OFF by default: break/continue loop falls back (no reduce_while)" do
      if python_available?() do
        Application.delete_env(:pylixir, :enable_t4_break_continue)

        src =
          Pylixir.transpile(
            "grid=[[1,2],[3,4]]\nfor row in grid:\n    row[0]=9\n    if row[1]==4:\n        break\nprint(grid)\n"
          )

        refute src =~ "reduce_while"
      end
    end
  end

  describe "T5 — type-proven op-narrowing" do
    @describetag :loop_mutation
    test "proven-list subscript get/set and list += emit native ops" do
      if python_available?() do
        src = run!("xs=[10,20,30]\nprint(xs[1])\n", "20\n")
        assert src =~ "Enum.at("
        refute src =~ "py_getitem"

        src = run!("xs=[1,2,3]\nxs[0]=9\nprint(xs)\n", "[9, 2, 3]\n")
        assert src =~ "List.replace_at("
        refute src =~ "py_setitem"

        src = run!("xs=[1,2]\nxs+=[3,4]\nprint(xs)\n", "[1, 2, 3, 4]\n")
        assert src =~ "++"
        refute src =~ "py_add"
      end
    end

    test "semantics preserved: negative index and out-of-range" do
      if python_available?() do
        run!("xs=[1,2,3]\nprint(xs[-1])\n", "3\n")
      end
    end

    test "non-list (dict) subscript is NOT narrowed (keeps py_getitem)" do
      if python_available?() do
        src = run!("d={'a':1}\nprint(d['a'])\n", "1\n")
        # The call site keeps `py_getitem` (dict, not is_list?); assert on
        # the call shape, not on `Enum.at(` which appears in the helper body.
        assert src =~ "py_getitem(@var_d"
        refute src =~ "Enum.at(@var_d"
      end
    end
  end
end
