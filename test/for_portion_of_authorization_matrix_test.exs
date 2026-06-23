# SPDX-FileCopyrightText: 2019 ash_postgres contributors <https://github.com/ash-project/ash_postgres/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshPostgres.ForPortionOfAuthorizationMatrixTest do
  @moduledoc """
  Authorization matrix for the `FOR PORTION OF` temporal mutation paths against a
  RECORD-CORRELATED policy (`owner == ^actor(:owner)`) for BOTH update and destroy
  (`AshPostgres.Test.OwnerGuardedRate`).

  Threat model: an actor who is authorized for the action in general (owns SOME period-row)
  but is NOT authorized for the specifically targeted period-row must never be able to clip
  (update) or delete that row. It must fail closed and leave the row byte-for-byte intact.

  Each scenario is exercised through the dispatch the temporal clip actually reaches with the
  current action configuration (empirically established):

    * single-record `Ash.update` / `Ash.destroy` (`require_atomic? false` temporal clip) is the
      streamed per-record `update/2` / `destroy/2` data-layer path. `Ash.Policy.Authorizer`
      gates it UPSTREAM of the data layer: a forbidden record-correlated clip is refused before
      the `FOR PORTION OF` statement is ever built, so the data layer is never handed a policy
      filter to enforce or drop.

    * `Ash.bulk_update` / `Ash.bulk_destroy` over a query reaches `update_query/4` /
      `destroy_query/4` with `changeset.data == %OriginalDataNotAvailable{}`. The policy filter
      is folded into the authorized `query`; `update_query/4` clips via a `(pk) IN (<query>)`
      membership clause built FROM that query, and `destroy_query/4` deletes the whole rows the
      query selects. Both therefore enforce the policy through the authorized query itself.

  Every scenario must refuse the unauthorized mutation and leave the target row intact.
  """
  use AshPostgres.RepoCase, async: false

  require Ash.Query

  alias AshPostgres.Test.OwnerGuardedRate

  @moduletag :postgres_19

  defp actor(owner), do: %{owner: owner}

  defp create_rate(opts) do
    OwnerGuardedRate
    |> Ash.Changeset.for_create(:create, %{
      code: opts[:code],
      owner: opts[:owner],
      monthly_price: Decimal.new(opts[:price]),
      valid_at: {opts[:from], opts[:to]}
    })
    |> Ash.create!(authorize?: false)
  end

  defp to_bounds(%Postgrex.Range{lower: lower, upper: upper}),
    do: {unbound_to_nil(lower), unbound_to_nil(upper)}

  defp unbound_to_nil(:unbound), do: nil
  defp unbound_to_nil(value), do: value

  defp range({lower, upper}) do
    %Postgrex.Range{
      lower: lower || :unbound,
      lower_inclusive: true,
      upper: upper || :unbound,
      upper_inclusive: false
    }
  end

  defp slices(owner, code) do
    OwnerGuardedRate
    |> Ash.Query.filter(code == ^code and owner == ^owner)
    |> Ash.Query.sort(valid_at: :asc)
    |> Ash.read!(authorize?: false)
    |> Enum.map(&{to_bounds(&1.valid_at), &1.monthly_price})
  end

  defp read_one(owner, code) do
    OwnerGuardedRate
    |> Ash.Query.filter(code == ^code and owner == ^owner)
    |> Ash.read_one!(authorize?: false)
  end

  defp seed_two_owners do
    create_rate(code: "pro", owner: "acme", price: "30.00", from: ~D[2026-01-01], to: nil)
    create_rate(code: "pro", owner: "globex", price: "99.00", from: ~D[2026-01-01], to: nil)
  end

  describe "single-record update (streamed update/2 path)" do
    test "an actor owning a sibling row cannot clip another owner's row: it fails closed and leaves the row intact" do
      seed_two_owners()

      assert {:error, %Ash.Error.Forbidden{}} =
               read_one("globex", "pro")
               |> Ash.Changeset.for_update(:change_price, %{
                 monthly_price: Decimal.new("60.00"),
                 valid_at: {~D[2026-06-16], nil}
               })
               |> Ash.update(actor: actor("acme"), authorize?: true)

      assert slices("globex", "pro") == [{{~D[2026-01-01], nil}, Decimal.new("99.00")}]
      assert slices("acme", "pro") == [{{~D[2026-01-01], nil}, Decimal.new("30.00")}]
    end

    test "the owning actor clips its own row into the expected old/new slices" do
      seed_two_owners()

      read_one("globex", "pro")
      |> Ash.Changeset.for_update(:change_price, %{
        monthly_price: Decimal.new("60.00"),
        valid_at: {~D[2026-06-16], nil}
      })
      |> Ash.update!(actor: actor("globex"), authorize?: true)

      assert slices("globex", "pro") == [
               {{~D[2026-01-01], ~D[2026-06-16]}, Decimal.new("99.00")},
               {{~D[2026-06-16], nil}, Decimal.new("60.00")}
             ]

      assert slices("acme", "pro") == [{{~D[2026-01-01], nil}, Decimal.new("30.00")}]
    end
  end

  describe "single-record destroy (streamed destroy/2 path)" do
    test "an actor owning a sibling row cannot delete another owner's whole row: it fails closed and leaves the row intact" do
      seed_two_owners()

      assert {:error, %Ash.Error.Forbidden{}} =
               read_one("globex", "pro")
               |> Ash.Changeset.for_destroy(:destroy, %{})
               |> Ash.destroy(actor: actor("acme"), authorize?: true)

      assert slices("globex", "pro") == [{{~D[2026-01-01], nil}, Decimal.new("99.00")}]
    end

    test "the owning actor deletes its own whole row" do
      seed_two_owners()

      read_one("globex", "pro")
      |> Ash.Changeset.for_destroy(:destroy, %{})
      |> Ash.destroy!(actor: actor("globex"), authorize?: true)

      assert slices("globex", "pro") == []
      assert slices("acme", "pro") == [{{~D[2026-01-01], nil}, Decimal.new("30.00")}]
    end

    test "an actor owning a sibling row cannot clip-delete a portion of another owner's row: it fails closed and leaves the row intact" do
      seed_two_owners()

      assert {:error, %Ash.Error.Forbidden{}} =
               %{read_one("globex", "pro") | valid_at: range({~D[2026-06-16], nil})}
               |> Ash.Changeset.for_destroy(:destroy, %{})
               |> Ash.destroy(actor: actor("acme"), authorize?: true)

      assert slices("globex", "pro") == [{{~D[2026-01-01], nil}, Decimal.new("99.00")}]
    end
  end

  describe "bulk update over a query (update_query/4 membership path)" do
    test "an unauthorized bulk_update over another owner's row clips nothing and leaves the row intact" do
      seed_two_owners()

      result =
        OwnerGuardedRate
        |> Ash.Query.filter(code == "pro" and owner == "globex")
        |> Ash.bulk_update(
          :change_price,
          %{monthly_price: Decimal.new("60.00"), valid_at: {~D[2026-06-16], nil}},
          actor: actor("acme"),
          authorize?: true,
          return_records?: true
        )

      assert %Ash.BulkResult{status: :success, records: []} = result
      assert slices("globex", "pro") == [{{~D[2026-01-01], nil}, Decimal.new("99.00")}]
    end

    test "an authorized bulk_update clips the actor's own matching rows" do
      seed_two_owners()

      OwnerGuardedRate
      |> Ash.Query.filter(code == "pro" and owner == "globex")
      |> Ash.bulk_update!(
        :change_price,
        %{monthly_price: Decimal.new("60.00"), valid_at: {~D[2026-06-16], nil}},
        actor: actor("globex"),
        authorize?: true
      )

      assert slices("globex", "pro") == [
               {{~D[2026-01-01], ~D[2026-06-16]}, Decimal.new("99.00")},
               {{~D[2026-06-16], nil}, Decimal.new("60.00")}
             ]
    end
  end

  describe "bulk destroy over a query (destroy_query/4 whole-row delete)" do
    test "an unauthorized bulk_destroy over another owner's row deletes nothing and leaves the row intact" do
      seed_two_owners()

      result =
        OwnerGuardedRate
        |> Ash.Query.filter(code == "pro" and owner == "globex")
        |> Ash.bulk_destroy(:destroy, %{}, actor: actor("acme"), authorize?: true, return_records?: true)

      assert %Ash.BulkResult{status: :success, records: []} = result
      assert slices("globex", "pro") == [{{~D[2026-01-01], nil}, Decimal.new("99.00")}]
    end

    test "an authorized bulk_destroy deletes the actor's own matching rows" do
      seed_two_owners()

      OwnerGuardedRate
      |> Ash.Query.filter(code == "pro" and owner == "globex")
      |> Ash.bulk_destroy!(:destroy, %{}, actor: actor("globex"), authorize?: true)

      assert slices("globex", "pro") == []
      assert slices("acme", "pro") == [{{~D[2026-01-01], nil}, Decimal.new("30.00")}]
    end
  end
end
