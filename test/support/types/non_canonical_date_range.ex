# SPDX-FileCopyrightText: 2019 ash_postgres contributors <https://github.com/ash-project/ash_postgres/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshPostgres.Test.NonCanonicalDateRange do
  @moduledoc """
  A deliberately misbehaving period type for issue #32: its `storage_type/1` of
  `:daterange` satisfies the compile-time temporal verifier, but its
  `cast_input`/`cast_stored` materialize the value as a plain `{lower, upper}`
  tuple rather than the `%Postgrex.Range{}` the data layer's runtime contract
  requires. Storage still works (`dump_to_native` converts back to a range), so
  the failure only surfaces when a temporal mutation reaches `period_bounds`.
  """
  use Ash.Type

  def storage_type(_), do: :daterange

  def cast_input(nil, _), do: {:ok, nil}
  def cast_input({%Date{}, nil} = range, _), do: {:ok, range}
  def cast_input({%Date{}, %Date{}} = range, _), do: {:ok, range}
  def cast_input(%Postgrex.Range{} = range, _), do: {:ok, to_tuple(range)}
  def cast_input(_, _), do: :error

  def cast_stored(nil, _), do: {:ok, nil}
  def cast_stored(%Postgrex.Range{} = range, _), do: {:ok, to_tuple(range)}
  def cast_stored(_, _), do: :error

  def dump_to_native(nil, _), do: {:ok, nil}
  def dump_to_native({lower, upper}, _), do: {:ok, to_postgrex(lower, upper)}
  def dump_to_native(%Postgrex.Range{} = range, _), do: {:ok, to_postgrex(range.lower, range.upper)}
  def dump_to_native(_, _), do: :error

  defp to_tuple(%Postgrex.Range{lower: lower, upper: upper}) do
    {unbound_to_nil(lower), unbound_to_nil(upper)}
  end

  defp to_postgrex(lower, upper) do
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
