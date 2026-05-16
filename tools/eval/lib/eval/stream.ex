defmodule Eval.Stream do
  @moduledoc """
  Stream samples from a Hugging Face dataset by driving
  `priv/python/dataset_stream.py` via a `Port`.

  The script emits one JSON object per line on stdout. Three line shapes:

    * `%{"id" => _, "source" => _}` — a real sample.
    * `%{"_skip" => reason, "id" => _}` — sample skipped (no Python found).
    * `%{"_done" => true, "emitted" => n}` — clean EOF marker.
    * `%{"_fatal" => message}` — fatal error inside the Python script.

  `stream/1` returns a `Stream.t/0` of decoded maps including skip lines,
  so callers can count them. The terminal `_done` / `_fatal` line is
  consumed internally and not yielded.

  A fatal envelope raises `Eval.Stream.FatalError` from inside the stream.
  """

  defmodule FatalError do
    @moduledoc false
    defexception [:message]
  end

  @script_path Path.expand("../../priv/python/dataset_stream.py", __DIR__)

  @doc """
  Open the dataset stream.

  ## Options

    * `:dataset` — HF dataset name (default `"microsoft/rStar-Coder"`).
    * `:split` — dataset split (default `"train"`).
    * `:limit` — stop after N samples (default: unlimited).
    * `:offset` — skip N samples before yielding.
    * `:field` — explicit source column; overrides auto-detect.
    * `:name` — optional HF dataset config name.
    * `:python` — interpreter override (default `python3` or `$PYLIXIR_PYTHON`).
  """
  @spec stream(keyword()) :: Enumerable.t()
  def stream(opts \\ []) do
    Stream.resource(
      fn -> open_port(opts) end,
      &next_line/1,
      &close_port/1
    )
  end

  defp open_port(opts) do
    python = opts[:python] || System.get_env("PYLIXIR_PYTHON") || "python3"
    args = [@script_path] ++ build_args(opts)

    port =
      Port.open(
        {:spawn_executable, find_executable!(python)},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          {:line, 1_048_576},
          {:args, args}
        ]
      )

    %{port: port, done: false}
  end

  defp build_args(opts) do
    Enum.flat_map(
      [
        {"--dataset", opts[:dataset]},
        {"--split", opts[:split]},
        {"--limit", opts[:limit]},
        {"--offset", opts[:offset]},
        {"--field", opts[:field]},
        {"--name", opts[:name]}
      ],
      fn
        {_flag, nil} -> []
        {flag, value} -> [flag, to_string(value)]
      end
    )
  end

  defp find_executable!(python) do
    case System.find_executable(python) do
      nil -> raise FatalError, message: "python interpreter not found: #{python}"
      path -> path
    end
  end

  defp next_line(%{done: true} = state), do: {:halt, state}

  defp next_line(%{port: port} = state) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        handle_line(line, state)

      {^port, {:data, {:noeol, _line}}} ->
        raise FatalError,
          message: "dataset_stream.py emitted a line larger than the buffer"

      {^port, {:exit_status, 0}} ->
        {:halt, %{state | done: true}}

      {^port, {:exit_status, status}} ->
        raise FatalError,
          message: "dataset_stream.py exited with status #{status}"
    end
  end

  defp handle_line(line, state) do
    case Jason.decode(line) do
      {:ok, %{"_fatal" => msg}} ->
        raise FatalError, message: msg

      {:ok, %{"_done" => true}} ->
        {:halt, %{state | done: true}}

      {:ok, decoded} ->
        {[decoded], state}

      {:error, _} ->
        # Non-JSON stderr line (e.g., HF progress) — discard.
        next_line(state)
    end
  end

  defp close_port(%{port: port}) do
    if Port.info(port), do: Port.close(port)
    :ok
  end
end
