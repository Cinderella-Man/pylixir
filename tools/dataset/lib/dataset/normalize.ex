defmodule Dataset.Normalize do
  @moduledoc """
  The conservative output normalizer — used **both** as the correctness
  match-gate and to produce the stored canonical `expected`. See
  docs/12_dataset-curation-plan.md §Normalization.

  Rule (in order):

    1. Decode bytes as UTF-8, falling back to **latin-1** if invalid (so
       no row crashes the pipeline on non-UTF-8 stdout).
    2. `CRLF → LF`.
    3. **Per-line trailing `[ \\t]` trim** (space + tab only — `\\r` is
       already handled by step 2; `\\f`/`\\v` are left alone to avoid
       conflating genuinely different output).
    4. Drop trailing blank lines and the final newline.

  **Leading and internal spacing is preserved exactly** — so `"1 2 3"` is
  NOT equal to `"1\\n2\\n3"`, and the normalizer never conflates
  structurally different output. The result is therefore *lossy* (exact
  trailing-newline state is unrecoverable); the dataset's contract is
  "compare under this normalizer", which is exactly what `equal?/2` does.
  """

  @doc """
  Normalize raw output bytes to the canonical comparable string.
  """
  @spec normalize(binary()) :: String.t()
  def normalize(bin) when is_binary(bin) do
    bin
    |> to_utf8()
    |> String.replace("\r\n", "\n")
    |> String.split("\n")
    |> Enum.map(&rstrip_spaces_tabs/1)
    |> Enum.join("\n")
    |> String.trim_trailing("\n")
  end

  @doc """
  True iff two raw outputs are equal after normalization.
  """
  @spec equal?(binary(), binary()) :: boolean()
  def equal?(a, b) when is_binary(a) and is_binary(b), do: normalize(a) == normalize(b)

  # --- Internals -------------------------------------------------------

  # Valid UTF-8 passes through; otherwise reinterpret the raw bytes as
  # latin-1 (every byte → a codepoint), which always yields valid UTF-8.
  defp to_utf8(bin) do
    if String.valid?(bin) do
      bin
    else
      :unicode.characters_to_binary(bin, :latin1)
    end
  end

  defp rstrip_spaces_tabs(line), do: String.replace(line, ~r/[ \t]+$/, "")
end
