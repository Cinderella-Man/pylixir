defmodule Pylixir.Stdlib.Collections do
  @moduledoc """
  Pylixir.Stdlib implementation for `import collections`. Routes
  `collections.<Name>(...)` calls to the same lowerings the bare-Name
  shortcuts use (Counter, defaultdict, deque all live in
  `Pylixir.Builtins`). With this, both `from collections import X`
  (already a no-op + bare-Name dispatch) and `import collections;
  collections.X(...)` work.

  Not supported: `OrderedDict`, `namedtuple`, `ChainMap`, `UserDict`
  — these don't have direct Elixir analogues without ClassDef support.
  """

  @behaviour Pylixir.Stdlib

  alias Pylixir.Builtins

  @impl true
  def attribute(_path, _node), do: :no_clause

  @impl true
  # Delegate the actual lowering to Builtins so `collections.Counter`
  # and `Counter` share one code path.
  def call([name], args, kwargs, _node) when name in ~w(Counter defaultdict deque) do
    Builtins.emit(name, args, kwargs)
  end

  def call(_path, _args, _kwargs, _node), do: :no_clause

  @impl true
  # `from collections import deque, Counter, defaultdict` — these are
  # all bare-Name builtins (handled via `Pylixir.Builtins`). Bind nil
  # as a sentinel; subsequent `Counter(...)` calls go through the
  # builtin path. Anything else is rejected — the previous Converter
  # implementation rejected unknown names too.
  def import_binding(n) when n in ~w(deque Counter defaultdict), do: {:ok, nil}
  def import_binding(_), do: :error
end
