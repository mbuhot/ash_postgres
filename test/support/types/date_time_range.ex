# SPDX-FileCopyrightText: 2019 ash_postgres contributors <https://github.com/ash-project/ash_postgres/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshPostgres.Test.DateTimeRange do
  @moduledoc """
  Ash type mapping a PostgreSQL `tstzrange` to a canonical `%Postgrex.Range{}`
  (`lower_inclusive: true`, `upper_inclusive: false`, an unbounded bound
  represented as `nil` in `lower`/`upper`). Exercises the temporal data layer
  with a range subtype other than `date`, proving the `FOR PORTION OF` rewrite is
  subtype-agnostic.
  """
  use Ash.Type

  def storage_type(_), do: :tstzrange

  def cast_input(nil, _), do: {:ok, nil}
  def cast_input({%DateTime{}, nil} = range, _), do: {:ok, canonical(range)}
  def cast_input({%DateTime{}, %DateTime{}} = range, _), do: {:ok, canonical(range)}
  def cast_input(%Postgrex.Range{} = range, _), do: {:ok, canonical(range)}
  def cast_input(_, _), do: :error

  def cast_stored(nil, _), do: {:ok, nil}
  def cast_stored(%Postgrex.Range{} = range, _), do: {:ok, canonical(range)}
  def cast_stored(_, _), do: :error

  def dump_to_native(nil, _), do: {:ok, nil}
  def dump_to_native(%Postgrex.Range{} = range, _), do: {:ok, to_postgrex(range)}
  def dump_to_native(_, _), do: :error

  defp canonical({%DateTime{} = lower, upper}) do
    %Postgrex.Range{
      lower: lower,
      lower_inclusive: true,
      upper: upper,
      upper_inclusive: false
    }
  end

  defp canonical(%Postgrex.Range{lower: lower, upper: upper}) do
    %Postgrex.Range{
      lower: unbound_to_nil(lower),
      lower_inclusive: true,
      upper: unbound_to_nil(upper),
      upper_inclusive: false
    }
  end

  defp to_postgrex(%Postgrex.Range{lower: lower, upper: upper}) do
    %Postgrex.Range{
      lower: lower || :unbound,
      lower_inclusive: true,
      upper: upper || :unbound,
      upper_inclusive: false
    }
  end

  defp unbound_to_nil(:unbound), do: nil
  defp unbound_to_nil(value), do: value
end
