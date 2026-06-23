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
  alias AshPostgres.Test.SourcedRate
  alias AshPostgres.Test.TenantRate
  alias AshPostgres.Test.TierPrice

  defp range({lower, upper}) do
    %Postgrex.Range{
      lower: lower || :unbound,
      lower_inclusive: true,
      upper: upper || :unbound,
      upper_inclusive: false
    }
  end

  test "an empty filter produces no IN(subquery) clause" do
    changeset =
      %TierPrice{code: "pro", valid_at: range({~D[2026-01-01], nil}), monthly_price: Decimal.new("30.00")}
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

    assert [~D[2026-06-16], "pro", %Decimal{}] = params
  end

  test "a non-empty filter embeds the entity-key IN(subquery), ANDed with the key equality" do
    changeset =
      %ContractRate{
        owner: "acme",
        code: "pro",
        valid_at: range({~D[2026-01-01], nil}),
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

  test "source-mapped attributes emit storage column names in update SQL" do
    changeset =
      %SourcedRate{code: "pro", valid_at: range({~D[2026-01-01], nil}), monthly_price: Decimal.new("30.00")}
      |> Map.update!(:__meta__, &Map.put(&1, :state, :loaded))
      |> Ash.Changeset.for_update(:change_price, %{
        monthly_price: Decimal.new("60.00"),
        valid_at: {~D[2026-06-16], nil}
      })

    {statement, _params, _columns} =
      AshPostgres.DataLayer.build_for_portion_of_update(
        SourcedRate,
        changeset,
        :valid_at,
        AshPostgres.TestRepo
      )

    assert statement =~ ~s|FOR PORTION OF "validPeriod"|
    assert statement =~ ~s|WHERE "entityCode" = $|
    assert statement =~ ~s|RETURNING "entityCode", "validPeriod", "monthlyPrice"|

    refute statement =~ ~s|"valid_at"|
    refute statement =~ ~s|"code"|
    refute statement =~ ~s|"monthly_price"|
  end

  test "source-mapped attributes emit storage columns in the (cols) IN(subquery) left side" do
    changeset =
      %SourcedRate{code: "pro", valid_at: range({~D[2026-01-01], nil}), monthly_price: Decimal.new("30.00")}
      |> Map.update!(:__meta__, &Map.put(&1, :state, :loaded))
      |> Ash.Changeset.for_update(:change_price, %{
        monthly_price: Decimal.new("60.00"),
        valid_at: {~D[2026-06-16], nil}
      })
      |> Ash.Changeset.filter(Ash.Expr.expr(monthly_price == 30))

    {statement, _params, _columns} =
      AshPostgres.DataLayer.build_for_portion_of_update(
        SourcedRate,
        changeset,
        :valid_at,
        AshPostgres.TestRepo
      )

    assert statement =~ ~s|("entityCode", "validPeriod") IN (|
  end

  test "source-mapped attributes emit storage column names in destroy SQL" do
    changeset =
      %SourcedRate{code: "pro", valid_at: range({~D[2026-01-01], nil}), monthly_price: Decimal.new("30.00")}
      |> Map.update!(:__meta__, &Map.put(&1, :state, :loaded))
      |> Ash.Changeset.for_destroy(:destroy, %{})

    {statement, _params} =
      AshPostgres.DataLayer.build_for_portion_of_destroy(
        SourcedRate,
        changeset,
        :valid_at,
        AshPostgres.TestRepo
      )

    assert statement =~ ~s|FOR PORTION OF "validPeriod"|
    assert statement =~ ~s|WHERE "entityCode" = $|

    refute statement =~ ~s|"valid_at"|
    refute statement =~ ~s|"code"|
  end

  test "context multitenancy schema-qualifies the update target and its IN(subquery) to the tenant schema" do
    changeset =
      %TenantRate{code: "pro", valid_at: range({~D[2026-01-01], nil}), monthly_price: Decimal.new("30.00")}
      |> Map.update!(:__meta__, &Map.put(&1, :state, :loaded))
      |> Ash.Changeset.for_update(
        :change_price,
        %{monthly_price: Decimal.new("60.00"), valid_at: {~D[2026-06-16], nil}},
        tenant: "acme"
      )

    {statement, _params, _columns} =
      AshPostgres.DataLayer.build_for_portion_of_update(
        TenantRate,
        changeset,
        :valid_at,
        AshPostgres.TestRepo
      )

    assert statement =~ ~s|UPDATE "acme"."tenant_rates" FOR PORTION OF "valid_at"|
    assert statement =~ ~s|IN (SELECT|
    assert statement =~ ~s|FROM "acme"."tenant_rates"|
  end

  test "context multitenancy schema-qualifies the destroy target and its IN(subquery) to the tenant schema" do
    changeset =
      %TenantRate{code: "pro", valid_at: range({~D[2026-01-01], nil}), monthly_price: Decimal.new("30.00")}
      |> Map.update!(:__meta__, &Map.put(&1, :state, :loaded))
      |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: "acme")

    {statement, _params} =
      AshPostgres.DataLayer.build_for_portion_of_destroy(
        TenantRate,
        changeset,
        :valid_at,
        AshPostgres.TestRepo
      )

    assert statement =~ ~s|DELETE FROM "acme"."tenant_rates" FOR PORTION OF "valid_at"|
    assert statement =~ ~s|IN (SELECT|
    assert statement =~ ~s|FROM "acme"."tenant_rates"|
  end
end
