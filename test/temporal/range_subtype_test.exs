# SPDX-FileCopyrightText: 2019 ash_postgres contributors <https://github.com/ash-project/ash_postgres/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshPostgres.Temporal.RangeSubtypeTest do
  @moduledoc """
  `cast_subtype/1` is the single source of truth mapping a PostgreSQL range
  storage type to the scalar SQL type its `FOR PORTION OF … FROM x TO y` bounds
  are cast to. It is a pure function and needs no database.
  """
  use ExUnit.Case, async: true

  alias AshPostgres.Temporal.RangeSubtype

  test "maps each built-in range storage type to its scalar subtype" do
    assert RangeSubtype.cast_subtype(:daterange) == {:ok, "date"}
    assert RangeSubtype.cast_subtype(:tsrange) == {:ok, "timestamp"}
    assert RangeSubtype.cast_subtype(:tstzrange) == {:ok, "timestamptz"}
    assert RangeSubtype.cast_subtype(:int4range) == {:ok, "integer"}
    assert RangeSubtype.cast_subtype(:int8range) == {:ok, "bigint"}
    assert RangeSubtype.cast_subtype(:numrange) == {:ok, "numeric"}
  end

  test "rejects multirange storage types" do
    assert RangeSubtype.cast_subtype(:datemultirange) == :error
    assert RangeSubtype.cast_subtype(:tsmultirange) == :error
  end

  test "rejects custom or unknown range storage types" do
    assert RangeSubtype.cast_subtype(:some_custom_range) == :error
    assert RangeSubtype.cast_subtype(:integer) == :error
  end
end
