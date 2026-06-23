# SPDX-FileCopyrightText: 2019 ash_postgres contributors <https://github.com/ash-project/ash_postgres/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshPostgres.ForPortionOfBulkTest do
  @moduledoc """
  A temporal `Ash.bulk_update` over a query is rewritten to one `UPDATE ... FOR PORTION OF`
  whose `WHERE` is the bulk query filter, so PostgreSQL clips every matching period-row
  independently; a single bulk MERGE (which has no `FOR PORTION OF`) would overwrite the
  whole rows instead of splitting them.

  A temporal `Ash.bulk_destroy` is a whole-row set delete: it removes the period-rows
  matching the query with a plain atomic `DELETE` (no `FOR PORTION OF`) and never clips.
  Clipping is single-record only, via the per-record `destroy/2` / `destroy_query/4` path.
  """
  use AshPostgres.RepoCase, async: false

  require Ash.Query

  alias AshPostgres.Test.TierPrice

  # FOR PORTION OF and WITHOUT OVERLAPS primary keys require PostgreSQL 19.
  @moduletag :postgres_19

  defp create_price(code, price, from, to) do
    TierPrice
    |> Ash.Changeset.for_create(:create, %{
      code: code,
      monthly_price: Decimal.new(price),
      valid_at: {from, to}
    })
    |> Ash.create!()
  end

  defp to_bounds(%Postgrex.Range{lower: lower, upper: upper}),
    do: {unbound_to_nil(lower), unbound_to_nil(upper)}

  defp unbound_to_nil(:unbound), do: nil
  defp unbound_to_nil(value), do: value

  defp versions(code) do
    TierPrice
    |> Ash.Query.filter(code == ^code)
    |> Ash.Query.sort(valid_at: :asc)
    |> Ash.read!()
    |> Enum.map(&{to_bounds(&1.valid_at), &1.monthly_price})
  end

  test "bulk_update clips each matching row independently via a filtered FOR PORTION OF" do
    create_price("pro", "30.00", ~D[2026-01-01], nil)
    create_price("ent", "50.00", ~D[2026-01-01], nil)

    TierPrice
    |> Ash.Query.filter(code in ["pro", "ent"])
    |> Ash.bulk_update!(:change_price, %{
      monthly_price: Decimal.new("99.00"),
      valid_at: {~D[2026-06-16], nil}
    })

    assert versions("pro") == [
             {{~D[2026-01-01], ~D[2026-06-16]}, Decimal.new("30.00")},
             {{~D[2026-06-16], nil}, Decimal.new("99.00")}
           ]

    assert versions("ent") == [
             {{~D[2026-01-01], ~D[2026-06-16]}, Decimal.new("50.00")},
             {{~D[2026-06-16], nil}, Decimal.new("99.00")}
           ]
  end

  test "bulk_update clips only the rows the bulk query selects, leaving non-matching rows whole" do
    create_price("pro", "30.00", ~D[2026-01-01], nil)
    create_price("ent", "50.00", ~D[2026-01-01], nil)

    TierPrice
    |> Ash.Query.filter(code == "pro")
    |> Ash.bulk_update!(:change_price, %{
      monthly_price: Decimal.new("99.00"),
      valid_at: {~D[2026-06-16], nil}
    })

    assert versions("pro") == [
             {{~D[2026-01-01], ~D[2026-06-16]}, Decimal.new("30.00")},
             {{~D[2026-06-16], nil}, Decimal.new("99.00")}
           ]

    assert versions("ent") == [{{~D[2026-01-01], nil}, Decimal.new("50.00")}]
  end

  test "bulk_destroy over a query deletes the whole matching rows atomically, without clipping" do
    create_price("pro", "30.00", ~D[2026-01-01], nil)
    create_price("ent", "50.00", ~D[2026-01-01], nil)

    TierPrice
    |> Ash.Query.filter(code in ["pro", "ent"])
    |> Ash.bulk_destroy!(:destroy, %{})

    assert versions("pro") == []
    assert versions("ent") == []
  end

  test "bulk_destroy deletes only the rows the query selects, leaving non-matching rows whole" do
    create_price("pro", "30.00", ~D[2026-01-01], nil)
    create_price("ent", "50.00", ~D[2026-01-01], nil)

    TierPrice
    |> Ash.Query.filter(code == "pro")
    |> Ash.bulk_destroy!(:destroy, %{})

    assert versions("pro") == []
    assert versions("ent") == [{{~D[2026-01-01], nil}, Decimal.new("50.00")}]
  end
end
