# SPDX-FileCopyrightText: 2019 ash_postgres contributors <https://github.com/ash-project/ash_postgres/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshPostgres.ForPortionOfPolicyTest do
  @moduledoc """
  `Ash.Policy.Authorizer` must gate the `FOR PORTION OF` mutation path: with `authorize?: true`,
  a period-row the policy forbids must not be clipped or deleted, while an allowed row
  clips/deletes normally.

  Update is gated by a record-correlated filter policy (`owner == ^actor(:owner)`), proving the
  policy filter is threaded through `changeset.filter` into the mutation's entity-key
  `IN (<subquery>)` clause rather than dropped. Destroy is gated by an admin-only policy.
  """
  use AshPostgres.RepoCase, async: false

  require Ash.Query

  alias AshPostgres.Test.GuardedRate

  @moduletag :postgres_19

  defp actor(owner), do: %{owner: owner}
  defp admin(owner), do: %{owner: owner, role: :admin}
  defp non_admin(owner), do: %{owner: owner, role: :member}

  defp create_rate(opts) do
    GuardedRate
    |> Ash.Changeset.for_create(:create, %{
      code: opts[:code],
      owner: opts[:owner],
      monthly_price: Decimal.new(opts[:price]),
      valid_at: {opts[:from], opts[:to]}
    })
    |> Ash.create!(authorize?: false)
  end

  defp slices(owner, code) do
    GuardedRate
    |> Ash.Query.filter(code == ^code and owner == ^owner)
    |> Ash.Query.sort(valid_at: :asc)
    |> Ash.read!(authorize?: false)
    |> Enum.map(&{&1.valid_at, &1.monthly_price})
  end

  test "forbidden row is not clipped: an update by a non-owning actor fails and leaves the row unchanged" do
    create_rate(code: "pro", owner: "acme", price: "30.00", from: ~D[2026-01-01], to: nil)

    rate =
      GuardedRate
      |> Ash.Query.filter(code == "pro" and owner == "acme")
      |> Ash.read_one!(authorize?: false)

    assert {:error, %Ash.Error.Forbidden{}} =
             rate
             |> Ash.Changeset.for_update(
               :change_price,
               %{monthly_price: Decimal.new("60.00"), valid_at: {~D[2026-06-16], nil}}
             )
             |> Ash.update(actor: actor("globex"), authorize?: true)

    assert slices("acme", "pro") == [{{~D[2026-01-01], nil}, Decimal.new("30.00")}]
  end

  test "allowed row clips: an update by the owning actor clips into the expected old/new slices" do
    create_rate(code: "pro", owner: "acme", price: "30.00", from: ~D[2026-01-01], to: nil)

    rate =
      GuardedRate
      |> Ash.Query.filter(code == "pro" and owner == "acme")
      |> Ash.read_one!(authorize?: false)

    rate
    |> Ash.Changeset.for_update(
      :change_price,
      %{monthly_price: Decimal.new("60.00"), valid_at: {~D[2026-06-16], nil}}
    )
    |> Ash.update!(actor: actor("acme"), authorize?: true)

    assert slices("acme", "pro") == [
             {{~D[2026-01-01], ~D[2026-06-16]}, Decimal.new("30.00")},
             {{~D[2026-06-16], nil}, Decimal.new("60.00")}
           ]
  end

  test "policy is correlated to the clipped row: an actor owning a sibling row cannot clip another owner's row" do
    create_rate(code: "pro", owner: "acme", price: "30.00", from: ~D[2026-01-01], to: nil)
    create_rate(code: "pro", owner: "globex", price: "99.00", from: ~D[2026-01-01], to: nil)

    globex_rate =
      GuardedRate
      |> Ash.Query.filter(code == "pro" and owner == "globex")
      |> Ash.read_one!(authorize?: false)

    assert {:error, %Ash.Error.Forbidden{}} =
             globex_rate
             |> Ash.Changeset.for_update(
               :change_price,
               %{monthly_price: Decimal.new("60.00"), valid_at: {~D[2026-06-16], nil}}
             )
             |> Ash.update(actor: actor("acme"), authorize?: true)

    assert slices("globex", "pro") == [{{~D[2026-01-01], nil}, Decimal.new("99.00")}]
    assert slices("acme", "pro") == [{{~D[2026-01-01], nil}, Decimal.new("30.00")}]
  end

  test "forbidden row is not deleted: a destroy by a non-admin actor fails and leaves the row unchanged" do
    create_rate(code: "pro", owner: "acme", price: "30.00", from: ~D[2026-01-01], to: nil)

    rate =
      GuardedRate
      |> Ash.Query.filter(code == "pro" and owner == "acme")
      |> Ash.read_one!(authorize?: false)

    assert {:error, %Ash.Error.Forbidden{}} =
             %{rate | valid_at: {~D[2026-06-16], nil}}
             |> Ash.Changeset.for_destroy(:destroy, %{})
             |> Ash.destroy(actor: non_admin("acme"), authorize?: true)

    assert slices("acme", "pro") == [{{~D[2026-01-01], nil}, Decimal.new("30.00")}]
  end

  test "allowed row clips on destroy: a destroy by an admin actor removes only the targeted portion" do
    create_rate(code: "pro", owner: "acme", price: "30.00", from: ~D[2026-01-01], to: nil)

    rate =
      GuardedRate
      |> Ash.Query.filter(code == "pro" and owner == "acme")
      |> Ash.read_one!(authorize?: false)

    %{rate | valid_at: {~D[2026-06-16], nil}}
    |> Ash.Changeset.for_destroy(:destroy, %{})
    |> Ash.destroy!(actor: admin("acme"), authorize?: true)

    assert slices("acme", "pro") == [
             {{~D[2026-01-01], ~D[2026-06-16]}, Decimal.new("30.00")}
           ]
  end
end
