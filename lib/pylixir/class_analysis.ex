defmodule Pylixir.ClassAnalysis do
  @moduledoc """
  Recognise the "simple data-class" subset of `class Foo: ...` that
  Pylixir's first-pass class support can lower. The data shape returned
  by `analyze/1` is consumed by `Pylixir.ModuleAnalysis` (to register
  the class for downstream `Foo(...)` call-site recognition) and by
  `Pylixir.Converter` (to emit a constructor `defp Foo__init__/N` and,
  later, per-method `defp Foo_<method>/N+1`).

  Simple-shape requirements (Loop 1 of the class build):

    * No `bases` (no inheritance) — Pylixir doesn't model MRO.
    * No `keywords` (no `metaclass=`).
    * No `decorator_list` (no `@dataclass`, no `@property`, etc.).
    * Every body item is a `FunctionDef`.
    * Exactly one `__init__` method.
    * Method args follow the `(self, ...)` shape.

  Anything else raises `Pylixir.UnsupportedNodeError(node_type: "ClassDef")`
  with a precise hint naming what's blocking it.

  Return shape:

      %{
        name: "Counter",
        init: %{args: [...], body: [...]},
        methods: [%{name: "...", args: [...], body: [...]}, ...]
      }

  `methods` excludes `__init__`. The args/body fields are raw Python AST
  nodes — the Converter walks them with `self` bound as a normal param.
  """

  alias Pylixir.UnsupportedNodeError

  @type method_spec :: %{
          required(:name) => String.t(),
          required(:args) => map(),
          required(:body) => [map()]
        }

  @type t :: %{
          required(:name) => String.t(),
          required(:init) => method_spec(),
          required(:methods) => [method_spec()]
        }

  @spec analyze(map()) :: t()
  def analyze(%{"_type" => "ClassDef"} = class_node) do
    name = Map.fetch!(class_node, "name")
    reject_non_simple_shape!(class_node, name)

    body = Map.fetch!(class_node, "body")
    method_nodes = Enum.map(body, &validate_method!(&1, name))

    {init_methods, other_methods} =
      Enum.split_with(method_nodes, fn m -> m.name == "__init__" end)

    init =
      case init_methods do
        [single] ->
          single

        [] ->
          raise UnsupportedNodeError,
            node_type: "ClassDef",
            hint:
              "class `#{name}` has no `__init__` — Pylixir's first-pass class lowering requires one (the data map is built from `self.x = ...` assignments in `__init__`).",
            lineno: Map.get(class_node, "lineno"),
            col_offset: Map.get(class_node, "col_offset")

        many ->
          raise UnsupportedNodeError,
            node_type: "ClassDef",
            hint:
              "class `#{name}` defines `__init__` #{length(many)} times (Python wouldn't either) — drop the extras",
            lineno: Map.get(class_node, "lineno")
      end

    %{name: name, init: init, methods: other_methods}
  end

  defp reject_non_simple_shape!(class_node, name) do
    cond do
      class_node["bases"] != [] ->
        raise UnsupportedNodeError,
          node_type: "ClassDef",
          hint:
            "class `#{name}` inherits from other classes — Pylixir's first-pass class lowering doesn't model inheritance. Flatten to a single class or factor shared logic into a free function.",
          lineno: Map.get(class_node, "lineno")

      class_node["keywords"] != [] ->
        raise UnsupportedNodeError,
          node_type: "ClassDef",
          hint:
            "class `#{name}` uses class-level keyword args (e.g. `metaclass=`) — not supported",
          lineno: Map.get(class_node, "lineno")

      class_node["decorator_list"] != [] ->
        raise UnsupportedNodeError,
          node_type: "ClassDef",
          hint:
            "class `#{name}` has decorators (`@...`) — Pylixir's first-pass class lowering can't model `@dataclass`, `@property`, etc.",
          lineno: Map.get(class_node, "lineno")

      true ->
        :ok
    end
  end

  defp validate_method!(%{"_type" => "FunctionDef"} = fn_node, _class_name) do
    method_name = Map.fetch!(fn_node, "name")
    args = Map.fetch!(fn_node, "args")
    body = Map.fetch!(fn_node, "body")

    case args["args"] do
      [%{"arg" => "self"} | _rest] ->
        :ok

      _ ->
        raise UnsupportedNodeError,
          node_type: "ClassDef",
          hint:
            "method `#{method_name}` does not take `self` as its first arg — Pylixir's class lowering models instance methods only (no `@classmethod` / `@staticmethod`)",
          lineno: Map.get(fn_node, "lineno")
    end

    if fn_node["decorator_list"] != [] do
      raise UnsupportedNodeError,
        node_type: "ClassDef",
        hint:
          "method `#{method_name}` is decorated (`@...`) — Pylixir's first-pass class lowering doesn't support method decorators",
        lineno: Map.get(fn_node, "lineno")
    end

    %{name: method_name, args: args, body: body}
  end

  defp validate_method!(node, class_name) do
    type = Map.get(node, "_type")

    raise UnsupportedNodeError,
      node_type: "ClassDef",
      hint:
        "class `#{class_name}` body contains a `#{type}` node — Pylixir's first-pass class lowering supports only `def`s (no class attributes, no nested classes, no docstrings — yet)",
      lineno: Map.get(node, "lineno")
  end
end
