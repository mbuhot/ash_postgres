# SPDX-FileCopyrightText: 2019 ash_postgres contributors <https://github.com/ash-project/ash_postgres/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshPostgres.Temporal.RangeSubtype do
  @moduledoc false

  @doc """
  Maps a PostgreSQL range storage type to the scalar SQL type its
  `FOR PORTION OF … FROM x TO y` bounds are cast to. Returns `:error` for any
  type that is not one of the built-in range types (custom and multirange types
  have no castable scalar bounds and are unsupported as temporal periods).
  """
  @spec cast_subtype(atom()) :: {:ok, String.t()} | :error
  def cast_subtype(:daterange), do: {:ok, "date"}
  def cast_subtype(:tsrange), do: {:ok, "timestamp"}
  def cast_subtype(:tstzrange), do: {:ok, "timestamptz"}
  def cast_subtype(:int4range), do: {:ok, "integer"}
  def cast_subtype(:int8range), do: {:ok, "bigint"}
  def cast_subtype(:numrange), do: {:ok, "numeric"}
  def cast_subtype(_), do: :error
end
