# SPDX-FileCopyrightText: 2019 ash_postgres contributors <https://github.com/ash-project/ash_postgres/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshPostgres.ForPortionOfSqlTest do
  @moduledoc """
  DB-free assertions on the SQL the `FOR PORTION OF` rewrite generates. An empty
  `changeset.filter` (and no tenant scoping) must omit the entity-key `IN (<subquery>)`
  clause; a non-empty filter must embed it, ANDed with the entity-key equality.
  """
  use ExUnit.Case, async: true

  require Ash.Expr

  alias AshPostgres.Test.ContractRate
  alias AshPostgres.Test.TierPrice

  test "an empty filter produces no IN(subquery) clause" do
    changeset =
      %TierPrice{code: "pro", valid_at: {~D[2026-01-01], nil}, monthly_price: Decimal.new("30.00")}
      |> Map.update!(:__meta__, &Map.put(&1, :state, :loaded))
      |> Ash.Changeset.for_update(:change_price, %{
        monthly_price: Decimal.new("60.00"),
        valid_at: {~D[2026-06-16], nil}
      })

    {statement, params, _columns} =
      AshPostgres.DataLayer.build_for_portion_of_update(
        TierPrice,
        changeset,
        :valid_at,
        AshPostgres.TestRepo
      )

    refute statement =~ "IN ("
    assert statement =~ ~s|UPDATE "tier_prices" FOR PORTION OF "valid_at"|
    assert statement =~ ~s|WHERE "code" = $|
    assert statement =~ "RETURNING"

    assert [~D[2026-06-16], %Decimal{}, "pro"] = params
  end

  test "a non-empty filter embeds the entity-key IN(subquery), ANDed with the key equality" do
    changeset =
      %ContractRate{
        owner: "acme",
        code: "pro",
        valid_at: {~D[2026-01-01], nil},
        monthly_price: Decimal.new("30.00"),
        active: true,
        version: 1
      }
      |> Map.update!(:__meta__, &Map.put(&1, :state, :loaded))
      |> Ash.Changeset.for_update(
        :change_active_price,
        %{monthly_price: Decimal.new("60.00"), valid_at: {~D[2026-06-16], nil}},
        tenant: "acme"
      )
      |> Ash.Changeset.filter(Ash.Expr.expr(active == true))

    {statement, params, _columns} =
      AshPostgres.DataLayer.build_for_portion_of_update(
        ContractRate,
        changeset,
        :valid_at,
        AshPostgres.TestRepo
      )

    assert statement =~ "IN (SELECT"
    # Correlated on the FULL primary key (incl. the period column), not just the entity key,
    # so the filter is checked against the exact stored row being clipped.
    assert statement =~ ~s|("code", "valid_at", "owner") IN (|
    assert statement =~ ~s|c0."active"|

    assert statement =~ "WHERE (c0.\"active\"::boolean = $1::boolean)"
    assert [true | _rest] = params
  end
end
