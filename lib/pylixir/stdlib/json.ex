defmodule Pylixir.Stdlib.Json do
  @moduledoc """
  Pylixir.Stdlib implementation for Python's `json` module —
  `json.dumps` (encoder) and `json.loads` (decoder).

  Backed by `py_json_dumps` / `py_json_loads` runtime helpers
  (custom encoder + Erlang's OTP-28 built-in `:json` for decode).
  Pylixir → JSON type mapping:

  | Python   | Pylixir runtime    | JSON       |
  | -------- | ------------------ | ---------- |
  | dict     | Map                | object     |
  | list     | List               | array      |
  | tuple    | tuple              | array      |
  | str      | binary             | string     |
  | int      | integer            | number     |
  | float    | float              | number     |
  | True     | true               | true       |
  | False    | false              | false      |
  | None     | nil                | null       |

  `indent=N` produces pretty-printed output indented by N spaces.
  Bound-method shapes like `json.JSONDecoder()` aren't supported.
  """

  @behaviour Pylixir.Stdlib

  @impl true
  def attribute(_path, _node), do: :no_clause

  @impl true
  def call(["dumps"], [value], kwargs, _node) do
    case Map.get(kwargs, "indent") do
      nil -> {:ok, {:py_json_dumps, [], [value]}}
      indent -> {:ok, {:py_json_dumps, [], [value, indent]}}
    end
  end

  def call(["loads"], [s], _kwargs, _node), do: {:ok, {:py_json_loads, [], [s]}}

  def call(_path, _args, _kwargs, _node), do: :no_clause

  @impl true
  def import_binding("dumps"), do: {:ok, Pylixir.Stdlib.capture(:py_json_dumps, 1)}
  def import_binding("loads"), do: {:ok, Pylixir.Stdlib.capture(:py_json_loads, 1)}
  def import_binding(_), do: :error
end
