defmodule TranslatedCode do
  def py_bool_str(true) do
    "True"
  end

  def py_bool_str(false) do
    "False"
  end

  def py_main do
    try do
      IO.write(Integer.to_string(String.length("hello")) <> "\n")
      IO.write(Integer.to_string(String.length("")) <> "\n")
      IO.write(py_bool_str(String.starts_with?("prefix_data", "prefix")) <> "\n")
      IO.write(py_bool_str(String.ends_with?("file.txt", ".txt")) <> "\n")
      IO.write(py_bool_str("abc" == "abc") <> "\n")
      IO.write(py_bool_str("abc" == "abd") <> "\n")
    catch
      :throw, {:pylixir_exit, code} -> code
    end
  end
end

TranslatedCode.py_main()