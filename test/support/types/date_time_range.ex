# SPDX-FileCopyrightText: 2019 ash_postgres contributors <https://github.com/ash-project/ash_postgres/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshPostgres.Test.DateTimeRange do
  @moduledoc """
  Ash type mapping a PostgreSQL `tstzrange` to a `{lower_datetime, upper_datetime}`
  tuple (unbounded upper is `nil`). Exercises the temporal data layer with a range
  subtype other than `date`, proving the `FOR PORTION OF` rewrite is subtype-agnostic.
  """
  use Ash.Type

  def storage_type(_), do: :tstzrange

  def cast_input(nil, _), do: {:ok, nil}
  def cast_input({%DateTime{}, nil} = range, _), do: {:ok, range}
  def cast_input({%DateTime{}, %DateTime{}} = range, _), do: {:ok, range}
  def cast_input(_, _), do: :error

  def cast_stored(nil, _), do: {:ok, nil}

  def cast_stored(%Postgrex.Range{lower: lower, upper: upper}, _),
    do: {:ok, {unbound_to_nil(lower), unbound_to_nil(upper)}}

  def cast_stored(_, _), do: :error

  def dump_to_native(nil, _), do: {:ok, nil}

  def dump_to_native({%DateTime{} = lower, upper}, _) do
    {:ok,
     %Postgrex.Range{
       lower: lower,
       lower_inclusive: true,
       upper: upper || :unbound,
       upper_inclusive: false
     }}
  end

  def dump_to_native(_, _), do: :error

  defp unbound_to_nil(:unbound), do: nil
  defp unbound_to_nil(value), do: value
end
