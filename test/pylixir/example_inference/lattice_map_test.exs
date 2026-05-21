defmodule Pylixir.ExampleInference.LatticeMapTest do
  use ExUnit.Case, async: true

  alias Pylixir.ExampleInference.LatticeMap

  defp module_env(locals) do
    %{
      "events" => [
        %{"event" => "module_end", "scope" => "module", "lineno" => nil, "locals" => locals}
      ],
      "uncaught" => nil,
      "truncated" => false
    }
  end

  describe "events_to_observations/1: scalars" do
    test "maps known scalar tags" do
      env =
        module_env(%{
          "n" => "int",
          "f" => "float",
          "b" => "bool",
          "s" => "str",
          "x" => "none"
        })

      assert LatticeMap.events_to_observations(env) == %{
               :module => %{
                 "n" => {:int},
                 "f" => {:float},
                 "b" => {:bool},
                 "s" => {:str},
                 "x" => {:none}
               }
             }
    end

    test "unknown scalar string falls through to :any" do
      env = module_env(%{"x" => "bytes"})
      assert LatticeMap.events_to_observations(env) == %{module: %{"x" => :any}}
    end

    test "any tag preserved" do
      env = module_env(%{"x" => "any"})
      assert LatticeMap.events_to_observations(env) == %{module: %{"x" => :any}}
    end
  end

  describe "events_to_observations/1: containers" do
    test "list of ints" do
      env = module_env(%{"xs" => %{"kind" => "list", "elems" => ["int", "int", "int"]}})
      assert LatticeMap.events_to_observations(env) == %{module: %{"xs" => {:list, {:int}}}}
    end

    test "empty list → list of :any" do
      env = module_env(%{"xs" => %{"kind" => "list", "elems" => []}})
      assert LatticeMap.events_to_observations(env) == %{module: %{"xs" => {:list, :any}}}
    end

    test "tuple keeps positional types" do
      env = module_env(%{"t" => %{"kind" => "tuple", "elems" => ["int", "str"]}})

      assert LatticeMap.events_to_observations(env) == %{
               module: %{"t" => {:tuple, [{:int}, {:str}]}}
             }
    end

    test "dict lubs keys and values across items" do
      env =
        module_env(%{
          "d" => %{
            "kind" => "dict",
            "items" => [["str", "int"], ["str", "int"]]
          }
        })

      assert LatticeMap.events_to_observations(env) == %{
               module: %{"d" => {:dict, {:str}, {:int}}}
             }
    end

    test "set is opaque" do
      env = module_env(%{"s" => %{"kind" => "set"}})
      assert LatticeMap.events_to_observations(env) == %{module: %{"s" => {:set}}}
    end

    test "nested list of list of int" do
      env =
        module_env(%{
          "g" => %{
            "kind" => "list",
            "elems" => [
              %{"kind" => "list", "elems" => ["int", "int"]},
              %{"kind" => "list", "elems" => ["int"]}
            ]
          }
        })

      assert LatticeMap.events_to_observations(env) == %{
               module: %{"g" => {:list, {:list, {:int}}}}
             }
    end
  end

  describe "merge_examples/1: uniformity filter (Q5 B)" do
    test "single envelope round-trips" do
      env = module_env(%{"n" => "int"})
      assert LatticeMap.merge_examples([env]) == %{module: %{"n" => {:int}}}
    end

    test "two envelopes agreeing → stable" do
      envs = [module_env(%{"n" => "int"}), module_env(%{"n" => "int"})]
      assert LatticeMap.merge_examples(envs) == %{module: %{"n" => {:int}}}
    end

    test "non-None obs disagreeing concretely → name excluded (softened)" do
      envs = [module_env(%{"x" => "int"}), module_env(%{"x" => "str"})]
      # Softened behavior: instead of raising, the conflicting name is
      # dropped. Other names (none in this case) still merge.
      assert LatticeMap.merge_examples(envs) == %{}
    end

    test "concrete + None → stable as union with :none" do
      envs = [module_env(%{"x" => "int"}), module_env(%{"x" => "none"})]
      result = LatticeMap.merge_examples(envs)
      assert {:union, set} = result.module["x"]
      assert MapSet.equal?(set, MapSet.new([{:int}, {:none}]))
    end

    test "all None → stable as {:none}" do
      envs = [module_env(%{"x" => "none"}), module_env(%{"x" => "none"})]
      assert LatticeMap.merge_examples(envs) == %{module: %{"x" => {:none}}}
    end

    test ":any obs ignored — concrete wins" do
      envs = [module_env(%{"x" => "int"}), module_env(%{"x" => "any"})]
      assert LatticeMap.merge_examples(envs) == %{module: %{"x" => {:int}}}
    end

    test "all :any → name excluded" do
      envs = [module_env(%{"x" => "any"}), module_env(%{"x" => "any"})]
      assert LatticeMap.merge_examples(envs) == %{}
    end

    test "int + int_lit_nonneg do not arise from tracer but lub via int" do
      # Tracer only emits "int" (no refinement). Sanity: same-type obs
      # always reconcile.
      envs = [module_env(%{"n" => "int"}), module_env(%{"n" => "int"})]
      assert LatticeMap.merge_examples(envs).module["n"] == {:int}
    end

    test "names appearing in only some envelopes still merge" do
      envs = [module_env(%{"a" => "int"}), module_env(%{"b" => "str"})]
      result = LatticeMap.merge_examples(envs)
      assert result.module["a"] == {:int}
      assert result.module["b"] == {:str}
    end
  end

  describe "merge_examples/1: edge cases" do
    test "empty envelope list → empty observations" do
      assert LatticeMap.merge_examples([]) == %{}
    end

    test "envelope with no events → empty" do
      env = %{"events" => [], "uncaught" => nil, "truncated" => false}
      assert LatticeMap.events_to_observations(env) == %{}
    end
  end
end
