# SPDX-FileCopyrightText: 2019 ash_postgres contributors <https://github.com/ash-project/ash_postgres/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshPostgres.Test.DateRange do
  @moduledoc """
  Minimal Ash type mapping a PostgreSQL `daterange` to a canonical
  `%Postgrex.Range{}` (`lower_inclusive: true`, `upper_inclusive: false`, an
  unbounded bound represented as `nil` in `lower`/`upper`). Its `storage_type/1`
  of `:daterange` is what marks it as an application-time period when used in a
  composite primary key.
  """
  use Ash.Type

  def storage_type(_), do: :daterange

  def cast_input(nil, _), do: {:ok, nil}
  def cast_input({%Date{}, nil} = range, _), do: {:ok, canonical(range)}
  def cast_input({%Date{}, %Date{}} = range, _), do: {:ok, canonical(range)}
  def cast_input(%Postgrex.Range{} = range, _), do: {:ok, canonical(range)}
  def cast_input(_, _), do: :error

  def cast_stored(nil, _), do: {:ok, nil}
  def cast_stored(%Postgrex.Range{} = range, _), do: {:ok, canonical(range)}
  def cast_stored(_, _), do: :error

  def dump_to_native(nil, _), do: {:ok, nil}
  def dump_to_native(%Postgrex.Range{} = range, _), do: {:ok, to_postgrex(range)}
  def dump_to_native(_, _), do: :error

  defp canonical({%Date{} = lower, upper}) do
    %Postgrex.Range{
      lower: lower,
      lower_inclusive: true,
      upper: upper,
      upper_inclusive: false
    }
  end

  defp canonical(%Postgrex.Range{
         lower: lower,
         lower_inclusive: lower_inclusive,
         upper: upper,
         upper_inclusive: upper_inclusive
       }) do
    %Postgrex.Range{
      lower: canonical_lower(lower, lower_inclusive),
      lower_inclusive: true,
      upper: canonical_upper(upper, upper_inclusive),
      upper_inclusive: false
    }
  end

  defp canonical_lower(:unbound, _), do: nil
  defp canonical_lower(nil, _), do: nil
  defp canonical_lower(date, true), do: date
  defp canonical_lower(date, false), do: Date.add(date, 1)

  defp canonical_upper(:unbound, _), do: nil
  defp canonical_upper(nil, _), do: nil
  defp canonical_upper(date, false), do: date
  defp canonical_upper(date, true), do: Date.add(date, 1)

  defp to_postgrex(%Postgrex.Range{lower: lower, upper: upper}) do
    %Postgrex.Range{
      lower: lower || :unbound,
      lower_inclusive: true,
      upper: upper || :unbound,
      upper_inclusive: false
    }
  end
end
