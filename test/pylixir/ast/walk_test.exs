defmodule Pylixir.AST.WalkTest do
  use ExUnit.Case, async: true

  alias Pylixir.AST.Walk

  describe "walk_scope/3" do
    test "visits every node in a flat tree (pre-order)" do
      tree = %{
        "_type" => "Module",
        "body" => [
          %{"_type" => "Assign", "targets" => [%{"_type" => "Name", "id" => "x"}]},
          %{"_type" => "Return", "value" => %{"_type" => "Name", "id" => "x"}}
        ]
      }

      types = Walk.walk_scope(tree, [], fn %{"_type" => t}, acc -> [t | acc] end)
      assert Enum.reverse(types) == ["Module", "Assign", "Name", "Return", "Name"]
    end

    test "does NOT descend into FunctionDef bodies" do
      tree = %{
        "_type" => "Module",
        "body" => [
          %{
            "_type" => "FunctionDef",
            "name" => "outer",
            "body" => [
              %{"_type" => "FunctionDef", "name" => "inner"},
              %{"_type" => "Return", "value" => nil}
            ]
          }
        ]
      }

      types = Walk.walk_scope(tree, [], fn %{"_type" => t}, acc -> [t | acc] end)

      assert "FunctionDef" in types
      refute "Return" in types
      assert types |> Enum.count(&(&1 == "FunctionDef")) == 1
    end

    test "does NOT descend into Lambda bodies" do
      tree = %{
        "_type" => "Lambda",
        "body" => %{"_type" => "Return", "value" => nil}
      }

      types = Walk.walk_scope(tree, [], fn %{"_type" => t}, acc -> [t | acc] end)
      assert types == ["Lambda"]
    end

    test "does NOT descend into ClassDef bodies" do
      tree = %{
        "_type" => "ClassDef",
        "body" => [%{"_type" => "FunctionDef", "name" => "method"}]
      }

      types = Walk.walk_scope(tree, [], fn %{"_type" => t}, acc -> [t | acc] end)
      assert types == ["ClassDef"]
    end

    for comp <- ~w(ListComp SetComp DictComp GeneratorExp) do
      test "does NOT descend into #{comp} subtrees" do
        tree = %{
          "_type" => unquote(comp),
          "elt" => %{"_type" => "Name", "id" => "x"},
          "generators" => []
        }

        types = Walk.walk_scope(tree, [], fn %{"_type" => t}, acc -> [t | acc] end)
        assert types == [unquote(comp)]
      end
    end

    test "descends through control-flow constructs (If, For, While)" do
      tree = %{
        "_type" => "If",
        "test" => %{"_type" => "Name", "id" => "cond"},
        "body" => [%{"_type" => "Return", "value" => nil}],
        "orelse" => []
      }

      types = Walk.walk_scope(tree, [], fn %{"_type" => t}, acc -> [t | acc] end)
      assert "Return" in types
    end
  end
end
