# SPDX-FileCopyrightText: 2019 ash_postgres contributors <https://github.com/ash-project/ash_postgres/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshPostgres.ForPortionOfBulkTest do
  @moduledoc """
  Temporal resources refuse the query/many mutation strategies, so `Ash.bulk_update`
  and `Ash.bulk_destroy` fall back to the per-record streaming path: one
  `UPDATE/DELETE ... FOR PORTION OF` per matching row. Each matching row is therefore
  clipped to the written period independently — a single bulk MERGE (which has no
  `FOR PORTION OF`) would overwrite the whole rows instead of splitting them.
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

  defp versions(code) do
    TierPrice
    |> Ash.Query.filter(code == ^code)
    |> Ash.Query.sort(valid_at: :asc)
    |> Ash.read!()
    |> Enum.map(&{&1.valid_at, &1.monthly_price})
  end

  test "bulk_update clips each matching row independently via per-record FOR PORTION OF" do
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

  test "bulk_destroy clips each matching row independently via per-record FOR PORTION OF" do
    create_price("pro", "30.00", ~D[2026-01-01], nil)
    create_price("ent", "50.00", ~D[2026-01-01], nil)

    rows =
      TierPrice
      |> Ash.Query.filter(code in ["pro", "ent"])
      |> Ash.read!()
      |> Enum.map(&%{&1 | valid_at: {~D[2026-06-16], nil}})

    Ash.bulk_destroy!(rows, :destroy, %{})

    assert versions("pro") == [{{~D[2026-01-01], ~D[2026-06-16]}, Decimal.new("30.00")}]
    assert versions("ent") == [{{~D[2026-01-01], ~D[2026-06-16]}, Decimal.new("50.00")}]
  end
end
