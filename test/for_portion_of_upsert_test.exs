# SPDX-FileCopyrightText: 2019 ash_postgres contributors <https://github.com/ash-project/ash_postgres/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshPostgres.ForPortionOfUpsertTest do
  @moduledoc """
  A temporal resource's primary key is a `WITHOUT OVERLAPS` GiST exclusion constraint, so the
  standard upsert (`ON CONFLICT`/`MERGE`) cannot apply. A temporal upsert instead means "assert
  these values for this period": the data layer vacates the asserted period across the entity's
  overlapping rows with `DELETE ... FOR PORTION OF`, then inserts the new period-row into the
  vacated interval. Neighbours are clipped at the asserted boundaries and gaps are filled.

  A plain (non-upsert) `create` of an overlapping period violates the exclusion constraint and is
  translated into a clean `Ash.Error.Invalid` (not `Ash.Error.Unknown`/`Postgrex.Error`).
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

  defp upsert_price(code, price, from, to) do
    TierPrice
    |> Ash.Changeset.for_create(:upsert_price, %{
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

  test "upsert overwrites an overlapping interior portion, clipping the neighbour on both sides" do
    create_price("pro", "30.00", ~D[2026-01-01], nil)

    upsert_price("pro", "99.00", ~D[2026-06-01], ~D[2026-09-01])

    assert versions("pro") == [
             {{~D[2026-01-01], ~D[2026-06-01]}, Decimal.new("30.00")},
             {{~D[2026-06-01], ~D[2026-09-01]}, Decimal.new("99.00")},
             {{~D[2026-09-01], nil}, Decimal.new("30.00")}
           ]
  end

  test "upsert fills a gap, leaving the disjoint existing row untouched" do
    create_price("pro", "30.00", ~D[2026-01-01], ~D[2026-03-01])

    upsert_price("pro", "99.00", ~D[2026-06-01], ~D[2026-09-01])

    assert versions("pro") == [
             {{~D[2026-01-01], ~D[2026-03-01]}, Decimal.new("30.00")},
             {{~D[2026-06-01], ~D[2026-09-01]}, Decimal.new("99.00")}
           ]
  end

  test "upsert over the exact existing period replaces its value" do
    create_price("pro", "30.00", ~D[2026-01-01], nil)

    upsert_price("pro", "99.00", ~D[2026-01-01], nil)

    assert versions("pro") == [{{~D[2026-01-01], nil}, Decimal.new("99.00")}]
  end

  test "upsert returns the inserted asserted period-row" do
    create_price("pro", "30.00", ~D[2026-01-01], nil)

    inserted = upsert_price("pro", "99.00", ~D[2026-06-01], ~D[2026-09-01])

    assert to_bounds(inserted.valid_at) == {~D[2026-06-01], ~D[2026-09-01]}
    assert inserted.monthly_price == Decimal.new("99.00")
  end

  test "bulk upsert vacates-then-inserts each changeset's period" do
    create_price("pro", "30.00", ~D[2026-01-01], nil)
    create_price("ent", "50.00", ~D[2026-01-01], nil)

    Ash.bulk_create!(
      [
        %{code: "pro", monthly_price: Decimal.new("99.00"), valid_at: {~D[2026-06-01], ~D[2026-09-01]}},
        %{code: "ent", monthly_price: Decimal.new("88.00"), valid_at: {~D[2026-06-01], ~D[2026-09-01]}}
      ],
      TierPrice,
      :upsert_price,
      return_records?: true,
      upsert_fields: [:monthly_price],
      domain: AshPostgres.Test.Domain
    )

    assert versions("pro") == [
             {{~D[2026-01-01], ~D[2026-06-01]}, Decimal.new("30.00")},
             {{~D[2026-06-01], ~D[2026-09-01]}, Decimal.new("99.00")},
             {{~D[2026-09-01], nil}, Decimal.new("30.00")}
           ]

    assert versions("ent") == [
             {{~D[2026-01-01], ~D[2026-06-01]}, Decimal.new("50.00")},
             {{~D[2026-06-01], ~D[2026-09-01]}, Decimal.new("88.00")},
             {{~D[2026-09-01], nil}, Decimal.new("50.00")}
           ]
  end

  test "a plain create of an overlapping period returns a translated Ash.Error.Invalid" do
    create_price("pro", "30.00", ~D[2026-01-01], nil)

    assert {:error, %Ash.Error.Invalid{} = error} =
             TierPrice
             |> Ash.Changeset.for_create(:create, %{
               code: "pro",
               monthly_price: Decimal.new("99.00"),
               valid_at: {~D[2026-06-01], ~D[2026-09-01]}
             })
             |> Ash.create()

    assert [%Ash.Error.Changes.InvalidChanges{fields: [:valid_at], message: message}] =
             error.errors

    assert message =~ "conflicts with an existing"

    assert versions("pro") == [{{~D[2026-01-01], nil}, Decimal.new("30.00")}]
  end
end
