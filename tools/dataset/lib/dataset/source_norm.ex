defmodule Dataset.SourceNorm do
  @moduledoc """
  Canonical-source hashing for the dedup source signal (`Dataset.Dedup`).

  Two LLM-generated task variations often ship the *same* solution modulo
  comments, whitespace, or variable names — byte-different source, and
  frequently zero testcase overlap, so neither of `Dataset.Dedup`'s
  intrinsic signals sees them. This module hashes each source in a
  **canonical** form so such pairs collide.

  Canonicalization is done by a small trusted Python script
  (`priv/source_norm.py`) because it needs CPython's AST. The script only
  **parses** the untrusted source (`ast.parse`) — it never executes it —
  so it runs outside the code sandbox. Modes:

    * `"reformat"` — `ast.unparse(ast.parse/1)`: ignores comments,
      whitespace, and quote style.
    * `"struct"` (default) — also renames every identifier, keeping
      operators and constants, so behaviour-equivalent renamings collide
      while different operators/constants stay distinct.

  All sources are hashed in **one** batch process (sources are small —
  code only). On any failure the step degrades to "no source signal"
  (empty map) rather than breaking the build.
  """

  require Logger

  @doc """
  Hash `id_sources` (`[{id, source}]`) into `%{id => sha_hex}`. Sources
  that fail to parse, and the whole step if the normalizer errors, are
  simply omitted (no edge).

  ## Options
    * `:mode` — `"reformat"` | `"struct"` (default `"struct"`).
    * `:python` — interpreter (default `Dataset.default_python/0`).
    * `:timeout_ms` — wall-clock budget for the batch (default 300_000).
  """
  @spec hashes([{String.t(), String.t()}], keyword()) :: %{String.t() => String.t()}
  def hashes(id_sources, opts \\ [])

  def hashes([], _opts), do: %{}

  def hashes(id_sources, opts) do
    mode = Keyword.get(opts, :mode, "struct")
    python = Keyword.get(opts, :python, Dataset.default_python())
    timeout_ms = Keyword.get(opts, :timeout_ms, 300_000)

    {ids, sources} = Enum.unzip(id_sources)
    input = Enum.map_join(sources, fn s -> Jason.encode!(s) <> "\n" end)

    with {:ok, out} <- run(python, mode, input, timeout_ms),
         lines = String.split(out, "\n", trim: true),
         true <- length(lines) == length(ids) do
      ids
      |> Enum.zip(lines)
      |> Enum.reduce(%{}, fn
        {_id, "ERR"}, acc -> acc
        {id, hash}, acc -> Map.put(acc, id, hash)
      end)
    else
      _ ->
        Logger.warning("[source-norm] normalizer unavailable/mismatched; skipping source signal")
        %{}
    end
  end

  # --- Internals -------------------------------------------------------

  defp run(python, mode, input, timeout_ms) do
    script = Path.join(:code.priv_dir(:pylixir_dataset), "source_norm.py")
    tmp = Path.join(System.tmp_dir!(), "source_norm_#{System.unique_integer([:positive])}.jsonl")

    try do
      File.write!(tmp, input)
      secs = Integer.to_string(div(timeout_ms, 1000))
      cmd = "exec #{q(python)} #{q(script)} #{q(mode)} < #{q(tmp)}"

      case System.cmd("timeout", [secs, "sh", "-c", cmd], stderr_to_stdout: false) do
        {out, 0} -> {:ok, out}
        {_out, _status} -> :error
      end
    rescue
      e ->
        Logger.warning("[source-norm] #{Exception.message(e)}")
        :error
    after
      File.rm(tmp)
    end
  end

  defp q(s), do: "'" <> String.replace(s, "'", "'\\''") <> "'"
end
