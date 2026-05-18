defmodule Pylixir.HelpersCodegenTest do
  use ExUnit.Case, async: true

  alias Pylixir.HelpersCodegen

  describe "helpers_source/0" do
    test "returns a non-empty string between the sentinel comments" do
      source = HelpersCodegen.helpers_source()

      assert is_binary(source)
      assert byte_size(source) > 0
      refute source =~ "HELPERS START"
      refute source =~ "HELPERS END"
    end

    test "compiles inside a throwaway defmodule" do
      # Catches helper-source breakage at unit-test time rather than only
      # at end-to-end Module emission. If a future helper edit introduces
      # a syntax error or compiler warning, this test fails fast.
      source = HelpersCodegen.helpers_source()
      wrapped = "defmodule ThrowawayHelpersCompileTest do\n#{source}\nend"

      {_result, diagnostics} =
        Code.with_diagnostics(fn -> Code.compile_string(wrapped) end)

      assert diagnostics == [],
             "helper slice produced unexpected diagnostics: " <> inspect(diagnostics)
    end
  end

  describe "helpers_ast/0" do
    test "returns a non-empty list of AST nodes" do
      ast = HelpersCodegen.helpers_ast()

      assert is_list(ast)
      refute ast == []
    end

    test "every node is a `def` AST" do
      for node <- HelpersCodegen.helpers_ast() do
        assert match?({:def, _, _}, node),
               "non-def AST node found in helpers list: #{inspect(node, limit: 3)}"
      end
    end
  end

  describe "helpers_ast_for/1" do
    defp clause_name({kind, _, [{:when, _, [{n, _, _}, _]}, _]}) when kind in [:def, :defp],
      do: n

    defp clause_name({kind, _, [{n, _, _}, _]}) when kind in [:def, :defp], do: n

    defp names(clauses), do: clauses |> Enum.map(&clause_name/1) |> Enum.uniq()

    test "no roots → no helpers spliced" do
      assert HelpersCodegen.helpers_ast_for([]) == []
      assert HelpersCodegen.helpers_ast_for([quote(do: 1 + 1)]) == []
    end

    test "py_add root pulls py_bool_to_int transitively" do
      root = quote(do: py_add(a, b))
      out = HelpersCodegen.helpers_ast_for([root])
      ns = names(out)

      assert :py_add in ns
      assert :py_bool_to_int in ns
      refute :py_re_findall in ns
      refute :py_format_value in ns
    end

    test "returned clauses stay as `def` (so unused-clause warnings don't fire)" do
      root = quote(do: py_add(a, b))
      out = HelpersCodegen.helpers_ast_for([root])

      refute out == []

      for clause <- out do
        assert match?({:def, _, _}, clause),
               "expected def (defp would trigger per-clause unused warnings); got: " <>
                 inspect(clause, limit: 3)
      end
    end

    test "multi-clause helpers come through with all their clauses" do
      root = quote(do: py_add(a, b))
      out = HelpersCodegen.helpers_ast_for([root])

      add_clauses = Enum.filter(out, &(clause_name(&1) == :py_add))

      full_add_arity =
        HelpersCodegen.helpers_ast()
        |> Enum.filter(fn {:def, _, [head, _]} ->
          head_name =
            case head do
              {:when, _, [{n, _, _}, _]} -> n
              {n, _, _} -> n
            end

          head_name == :py_add
        end)
        |> length()

      assert length(add_clauses) == full_add_arity,
             "expected all py_add clauses (#{full_add_arity}), got #{length(add_clauses)}"
    end

    test "capture references (`&truthy?/1`) are detected as helper roots" do
      root = quote(do: Enum.any?(xs, &truthy?/1))
      out = HelpersCodegen.helpers_ast_for([root])

      assert :truthy? in names(out)
    end

    test "unused helpers are excluded" do
      root = quote(do: py_len(xs))
      out = HelpersCodegen.helpers_ast_for([root])
      ns = names(out)

      assert :py_len in ns
      refute :py_re_findall in ns
      refute :py_math_comb in ns
      refute :py_str_percent_format in ns
    end

    test "splice order matches canonical helper order" do
      # Splice subset must be a *subsequence* of the canonical order of
      # the full helper list — same relative positions, just gaps.
      canonical = HelpersCodegen.helpers_ast() |> names()

      root = quote(do: py_add(py_len(x), py_str(y)))
      out_names = HelpersCodegen.helpers_ast_for([root]) |> names()

      out_positions = Enum.map(out_names, &Enum.find_index(canonical, fn n -> n == &1 end))

      assert out_positions == Enum.sort(out_positions),
             "spliced helpers reordered relative to canonical: #{inspect(out_names)}"
    end
  end
end
