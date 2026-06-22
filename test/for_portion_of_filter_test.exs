# SPDX-FileCopyrightText: 2019 ash_postgres contributors <https://github.com/ash-project/ash_postgres/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshPostgres.ForPortionOfFilterTest do
  @moduledoc """
  The `FOR PORTION OF` rewrite must thread `changeset.filter` (policy/action filters,
  attribute-multitenancy scoping, and the optimistic-lock predicate) into the mutation as
  an entity-key `IN (<subquery>)` clause, return the real clipped row from `RETURNING`,
  raise `StaleRecord` on a no-op, and translate constraint violations.
  """
  use AshPostgres.RepoCase, async: false

  require Ash.Query

  alias AshPostgres.Test.ContractRate

  @moduletag :postgres_19

  defp create_rate(opts) do
    ContractRate
    |> Ash.Changeset.for_create(
      :create,
      %{
        code: opts[:code],
        owner: opts[:owner],
        monthly_price: Decimal.new(opts[:price]),
        valid_at: {opts[:from], opts[:to]},
        active: Keyword.get(opts, :active, true),
        version: Keyword.get(opts, :version, 1)
      },
      tenant: opts[:owner]
    )
    |> Ash.create!()
  end

  defp versions(owner, code) do
    ContractRate
    |> Ash.Query.filter(code == ^code)
    |> Ash.Query.sort(valid_at: :asc)
    |> Ash.read!(tenant: owner)
    |> Enum.map(&{&1.valid_at, &1.monthly_price})
  end

  test "an action filter excludes a non-matching row: the temporal update does NOT touch it" do
    create_rate(code: "pro", owner: "acme", price: "30.00", from: ~D[2026-01-01], to: nil, active: false)

    rate =
      ContractRate
      |> Ash.Query.filter(code == "pro")
      |> Ash.read_one!(tenant: "acme")

    assert {:error, %Ash.Error.Invalid{}} =
             rate
             |> Ash.Changeset.for_update(
               :change_active_price,
               %{monthly_price: Decimal.new("60.00"), valid_at: {~D[2026-06-16], nil}},
               tenant: "acme"
             )
             |> Ash.update()

    assert versions("acme", "pro") == [{{~D[2026-01-01], nil}, Decimal.new("30.00")}]
  end

  test "an action filter excludes a non-matching row: the temporal destroy does NOT touch it" do
    create_rate(code: "pro", owner: "acme", price: "30.00", from: ~D[2026-01-01], to: nil, active: false)

    rate =
      ContractRate
      |> Ash.Query.filter(code == "pro")
      |> Ash.read_one!(tenant: "acme")

    assert {:error, %Ash.Error.Invalid{}} =
             %{rate | valid_at: {~D[2026-06-16], nil}}
             |> Ash.Changeset.for_destroy(:destroy_active, %{}, tenant: "acme")
             |> Ash.destroy()

    assert versions("acme", "pro") == [{{~D[2026-01-01], nil}, Decimal.new("30.00")}]
  end

  test "attribute multitenancy isolates tenants: an update in tenant A does not clip tenant B's row" do
    create_rate(code: "pro", owner: "acme", price: "30.00", from: ~D[2026-01-01], to: nil)
    create_rate(code: "pro", owner: "globex", price: "99.00", from: ~D[2026-01-01], to: nil)

    rate_a =
      ContractRate
      |> Ash.Query.filter(code == "pro")
      |> Ash.read_one!(tenant: "acme")

    rate_a
    |> Ash.Changeset.for_update(
      :change_price,
      %{monthly_price: Decimal.new("60.00"), valid_at: {~D[2026-06-16], nil}},
      tenant: "acme"
    )
    |> Ash.update!()

    assert versions("acme", "pro") == [
             {{~D[2026-01-01], ~D[2026-06-16]}, Decimal.new("30.00")},
             {{~D[2026-06-16], nil}, Decimal.new("60.00")}
           ]

    assert versions("globex", "pro") == [{{~D[2026-01-01], nil}, Decimal.new("99.00")}]
  end

  test "optimistic lock conflict surfaces as an error, not a silent no-op" do
    create_rate(code: "pro", owner: "acme", price: "30.00", from: ~D[2026-01-01], to: nil, version: 1)

    rate =
      ContractRate
      |> Ash.Query.filter(code == "pro")
      |> Ash.read_one!(tenant: "acme")

    stale = %{rate | version: 7}

    assert {:error, %Ash.Error.Invalid{}} =
             stale
             |> Ash.Changeset.for_update(
               :change_price_locked,
               %{monthly_price: Decimal.new("60.00"), valid_at: {~D[2026-06-16], nil}},
               tenant: "acme"
             )
             |> Ash.update()

    assert versions("acme", "pro") == [{{~D[2026-01-01], nil}, Decimal.new("30.00")}]
  end

  test "a matching optimistic-locked update succeeds and clips" do
    create_rate(code: "pro", owner: "acme", price: "30.00", from: ~D[2026-01-01], to: nil, version: 1)

    rate =
      ContractRate
      |> Ash.Query.filter(code == "pro")
      |> Ash.read_one!(tenant: "acme")

    rate
    |> Ash.Changeset.for_update(
      :change_price_locked,
      %{monthly_price: Decimal.new("60.00"), valid_at: {~D[2026-06-16], nil}},
      tenant: "acme"
    )
    |> Ash.update!()

    assert versions("acme", "pro") == [
             {{~D[2026-01-01], ~D[2026-06-16]}, Decimal.new("30.00")},
             {{~D[2026-06-16], nil}, Decimal.new("60.00")}
           ]
  end

  test "zero matching rows raises StaleRecord" do
    create_rate(code: "pro", owner: "acme", price: "30.00", from: ~D[2026-01-01], to: nil, active: true)

    rate =
      ContractRate
      |> Ash.Query.filter(code == "pro")
      |> Ash.read_one!(tenant: "acme")

    nonexistent = %{rate | code: "ghost"}

    assert {:error, %Ash.Error.Invalid{errors: errors}} =
             nonexistent
             |> Ash.Changeset.for_update(
               :change_price,
               %{monthly_price: Decimal.new("60.00"), valid_at: {~D[2026-06-16], nil}},
               tenant: "acme"
             )
             |> Ash.update()

    assert Enum.any?(errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1))
  end

  test "RETURNING gives the real clipped slice, not a fabricated record" do
    create_rate(code: "pro", owner: "acme", price: "30.00", from: ~D[2026-01-01], to: nil)

    rate =
      ContractRate
      |> Ash.Query.filter(code == "pro")
      |> Ash.read_one!(tenant: "acme")

    updated =
      rate
      |> Ash.Changeset.for_update(
        :change_price,
        %{monthly_price: Decimal.new("60.00"), valid_at: {~D[2026-06-16], nil}},
        tenant: "acme"
      )
      |> Ash.update!()

    assert updated.monthly_price == Decimal.new("60.00")
    assert updated.valid_at == {~D[2026-06-16], nil}
    assert updated.code == "pro"
    assert updated.owner == "acme"
  end

  test "a check-constraint violation surfaces as a translated Ash.Error, not a raw Postgrex.Error" do
    create_rate(code: "pro", owner: "acme", price: "30.00", from: ~D[2026-01-01], to: nil)

    rate =
      ContractRate
      |> Ash.Query.filter(code == "pro")
      |> Ash.read_one!(tenant: "acme")

    result =
      rate
      |> Ash.Changeset.for_update(
        :change_price,
        %{monthly_price: Decimal.new("-5.00"), valid_at: {~D[2026-06-16], nil}},
        tenant: "acme"
      )
      |> Ash.update()

    assert {:error, %Ash.Error.Invalid{} = error} = result
    refute match?(%Postgrex.Error{}, error)
    assert Exception.message(error) =~ "non-negative"
  end
end
