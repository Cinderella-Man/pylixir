defmodule Pylixir.ExampleInference do
  @moduledoc """
  Example-driven type inference orchestrator (docs/09).

  Public entry point: `seed/4`. Runs the tracer over each user-supplied
  example, lubs the observations, and writes `ctx.assume_types` (and
  later `ctx.fn_signatures`, `ctx.boundary_sites`). Cross-example
  conflicts surface as `Pylixir.ExampleConflictError`.
  """

  alias Pylixir.{Context, ExampleInference.BoundaryAnalysis, ExampleInference.LatticeMap}

  require Logger

  @default_python "python3.14"
  @default_trace_timeout_ms 2_000

  @doc """
  Populate example-derived fields of `ctx` from `examples`.

  Each example is a map with at least `:stdin` (binary). If the example
  carries pre-computed `:trace_events` (a tracer envelope map), they are
  used directly; otherwise the tracer is invoked with the Python source
  passed via `:source`.

  Step 4 wiring: only `ctx.assume_types` is populated. Later steps add
  `ctx.fn_signatures` (annotation channel) and `ctx.boundary_sites`.
  """
  @spec seed([map()], [map()], Context.t(), keyword()) :: Context.t()
  def seed(_body, [], ctx, _opts), do: ctx

  def seed(body, examples, ctx, opts) when is_list(examples) do
    source = Keyword.get(opts, :source)

    envelopes =
      examples
      |> Enum.map(&envelope_for(&1, source))
      |> Enum.reject(&is_nil/1)

    case envelopes do
      [] ->
        ctx

      _ ->
        assume_types = LatticeMap.merge_examples(envelopes)
        assume_fn_signatures = LatticeMap.merge_fn_signatures(envelopes)
        boundary_sites = build_boundary_sites(body, assume_types)
        partial? = Enum.any?(envelopes, &has_uncaught?/1)

        %{
          ctx
          | assume_types: assume_types,
            assume_fn_signatures: assume_fn_signatures,
            assume_types_partial?: partial?,
            boundary_sites: boundary_sites
        }
    end
  end

  defp has_uncaught?(%{"uncaught" => x}) when not is_nil(x), do: true
  defp has_uncaught?(_), do: false

  defp build_boundary_sites(body, assume_types) do
    candidates = BoundaryAnalysis.analyze(body)
    module_types = Map.get(assume_types, :module, %{})

    Enum.reduce(candidates, %{}, fn {lineno, name}, acc ->
      case Map.fetch(module_types, name) do
        {:ok, type} -> Map.put(acc, lineno, {name, type})
        :error -> acc
      end
    end)
  end

  defp envelope_for(%{trace_events: env}, _source) when is_map(env), do: env

  defp envelope_for(%{stdin: stdin}, source) when is_binary(source) and is_binary(stdin) do
    case run_tracer(source, stdin) do
      {:ok, env} ->
        if Map.get(env, "truncated") == true do
          Logger.warning("pylixir tracer hit size cap; using truncated trace")
        end

        env

      {:error, :timeout} ->
        Logger.warning(
          "pylixir tracer timeout (>#{@default_trace_timeout_ms}ms); skipping example"
        )

        nil

      {:error, {:tracer_exit, code, output}} ->
        Logger.warning(
          "pylixir tracer exited #{code}; skipping example. stderr_tail=#{inspect(tail(output))}"
        )

        nil

      {:error, reason} ->
        Logger.warning("pylixir tracer error #{inspect(reason)}; skipping example")
        nil
    end
  end

  defp envelope_for(_other, _source), do: nil

  defp tail(s) when is_binary(s) do
    if byte_size(s) > 512, do: binary_part(s, byte_size(s) - 512, 512), else: s
  end

  defp tail(s), do: inspect(s)

  @doc """
  Invoke `priv/python/trace.py` with the given Python source and stdin,
  returning the decoded JSON envelope on success.

  Returns `{:ok, envelope}` where envelope follows the shape locked in
  `trace.py`'s module docstring, or `{:error, reason}` on failure
  (tracer crash, JSON decode failure, etc.).
  """
  @spec run_tracer(String.t(), String.t(), keyword()) ::
          {:ok, map()}
          | {:error,
             :timeout
             | {:tracer_exit, integer(), String.t()}
             | {:decode, term()}}
  def run_tracer(source, stdin, opts \\ []) when is_binary(source) and is_binary(stdin) do
    case run_tracer_with_stdout(source, stdin, opts) do
      {:ok, {_stdout, envelope}} -> {:ok, envelope}
      {:error, _} = err -> err
    end
  end

  @doc """
  Variant of `run_tracer/3` that also returns the user program's
  captured stdout. Used by the eval harness to fold the tracer run and
  CPython preflight into one CPython invocation.
  """
  @spec run_tracer_with_stdout(String.t(), String.t(), keyword()) ::
          {:ok, {String.t(), map()}}
          | {:error,
             :timeout
             | {:tracer_exit, integer(), String.t()}
             | {:decode, term()}}
  def run_tracer_with_stdout(source, stdin, opts \\ [])
      when is_binary(source) and is_binary(stdin) do
    python = System.get_env("PYLIXIR_PYTHON") || @default_python
    script = Path.join([:code.priv_dir(:pylixir), "python", "trace.py"])
    timeout_ms = Keyword.get(opts, :trace_timeout_ms, @default_trace_timeout_ms)

    {source_path, stdin_path, out_path} = mktemps()
    File.write!(source_path, source)
    File.write!(stdin_path, stdin)

    try do
      task =
        Task.async(fn ->
          # stderr_to_stdout: false so the user program's stdout isn't
          # contaminated with tracer warnings; on failure we surface
          # the (combined) output from a second System.cmd below.
          System.cmd(python, [script, source_path, stdin_path, out_path], stderr_to_stdout: false)
        end)

      case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, {user_stdout, 0}} ->
          case File.read(out_path) do
            {:ok, ""} ->
              {:error, {:tracer_exit, 0, "empty out file"}}

            {:ok, payload} ->
              case Jason.decode(payload) do
                {:ok, envelope} -> {:ok, {user_stdout, envelope}}
                {:error, reason} -> {:error, {:decode, reason}}
              end

            {:error, reason} ->
              {:error, {:tracer_exit, 0, "out file unreadable: #{inspect(reason)}"}}
          end

        {:ok, {output, code}} ->
          {:error, {:tracer_exit, code, output}}

        nil ->
          {:error, :timeout}
      end
    after
      for path <- [source_path, stdin_path, out_path], do: File.rm(path)
    end
  end

  defp mktemps do
    base = :erlang.unique_integer([:positive])
    tmp = System.tmp_dir!()

    {
      Path.join(tmp, "pylixir-trace-#{base}.py"),
      Path.join(tmp, "pylixir-trace-#{base}.stdin"),
      Path.join(tmp, "pylixir-trace-#{base}.json")
    }
  end
end
