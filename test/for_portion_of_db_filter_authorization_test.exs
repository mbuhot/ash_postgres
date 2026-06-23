# SPDX-FileCopyrightText: 2019 ash_postgres contributors <https://github.com/ash-project/ash_postgres/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshPostgres.ForPortionOfDbFilterAuthorizationTest do
  @moduledoc """
  Authorization matrix for the `FOR PORTION OF` temporal mutation paths against a policy that
  `Ash.Policy.Authorizer` CANNOT strict-check in memory and so MUST apply as a runtime
  DATA-LAYER FILTER — exactly the shape issue #21 describes ("policy filters are applied to the
  query").

  `AshPostgres.Test.FragmentGuardedRate` guards both `:update` and `:destroy` with
  `authorize_if expr(fragment("? = ?", owner, ^actor(:owner)))`. A raw SQL fragment is opaque to
  Elixir, so the authorizer cannot resolve it against the loaded record and must push it through
  the `alter_query` path as a filter on the data-layer query.

  Threat model: actor "acme" is authorized for the action in general (owns row A) but targets
  globex's row B. Every unauthorized clip/delete must be REFUSED and row B left byte-for-byte
  intact. Each scenario is exercised across single-record (streamed `update/2` / `destroy/2`) and
  bulk (`update_query/4` / `destroy_query/4`) dispatch.
  """
  use AshPostgres.RepoCase, async: false

  require Ash.Query

  alias AshPostgres.Test.FragmentGuardedRate

  @moduletag :postgres_19

  defp actor(owner), do: %{owner: owner}

  defp create_rate(opts) do
    FragmentGuardedRate
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
    FragmentGuardedRate
    |> Ash.Query.filter(code == ^code and owner == ^owner)
    |> Ash.Query.sort(valid_at: :asc)
    |> Ash.read!(authorize?: false)
    |> Enum.map(&{to_bounds(&1.valid_at), &1.monthly_price})
  end

  defp read_one(owner, code) do
    FragmentGuardedRate
    |> Ash.Query.filter(code == ^code and owner == ^owner)
    |> Ash.read_one!(authorize?: false)
  end

  defp seed_two_owners do
    create_rate(code: "pro", owner: "acme", price: "30.00", from: ~D[2026-01-01], to: nil)
    create_rate(code: "pro", owner: "globex", price: "99.00", from: ~D[2026-01-01], to: nil)
  end

  describe "single-record update (streamed update/2 path)" do
    test "acme cannot clip globex's row: refused, globex row intact" do
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

    test "globex clips its own row into the expected old/new slices" do
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
    test "acme cannot delete globex's whole row: refused, globex row intact" do
      seed_two_owners()

      assert {:error, %Ash.Error.Forbidden{}} =
               read_one("globex", "pro")
               |> Ash.Changeset.for_destroy(:destroy, %{})
               |> Ash.destroy(actor: actor("acme"), authorize?: true)

      assert slices("globex", "pro") == [{{~D[2026-01-01], nil}, Decimal.new("99.00")}]
    end

    test "globex deletes its own whole row" do
      seed_two_owners()

      read_one("globex", "pro")
      |> Ash.Changeset.for_destroy(:destroy, %{})
      |> Ash.destroy!(actor: actor("globex"), authorize?: true)

      assert slices("globex", "pro") == []
      assert slices("acme", "pro") == [{{~D[2026-01-01], nil}, Decimal.new("30.00")}]
    end

    test "acme cannot clip-delete a portion of globex's row: refused, globex row intact" do
      seed_two_owners()

      assert {:error, %Ash.Error.Forbidden{}} =
               %{read_one("globex", "pro") | valid_at: range({~D[2026-06-16], nil})}
               |> Ash.Changeset.for_destroy(:destroy, %{})
               |> Ash.destroy(actor: actor("acme"), authorize?: true)

      assert slices("globex", "pro") == [{{~D[2026-01-01], nil}, Decimal.new("99.00")}]
    end
  end

  describe "bulk update over a query (update_query/4 membership path)" do
    test "acme's bulk_update over globex's row clips nothing, globex row intact" do
      seed_two_owners()

      result =
        FragmentGuardedRate
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

    test "globex's bulk_update clips its own matching rows" do
      seed_two_owners()

      FragmentGuardedRate
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
    test "acme's bulk_destroy over globex's row deletes nothing, globex row intact" do
      seed_two_owners()

      result =
        FragmentGuardedRate
        |> Ash.Query.filter(code == "pro" and owner == "globex")
        |> Ash.bulk_destroy(:destroy, %{},
          actor: actor("acme"),
          authorize?: true,
          return_records?: true
        )

      assert %Ash.BulkResult{status: :success, records: []} = result
      assert slices("globex", "pro") == [{{~D[2026-01-01], nil}, Decimal.new("99.00")}]
    end

    test "globex's bulk_destroy deletes its own matching rows" do
      seed_two_owners()

      FragmentGuardedRate
      |> Ash.Query.filter(code == "pro" and owner == "globex")
      |> Ash.bulk_destroy!(:destroy, %{}, actor: actor("globex"), authorize?: true)

      assert slices("globex", "pro") == []
      assert slices("acme", "pro") == [{{~D[2026-01-01], nil}, Decimal.new("30.00")}]
    end
  end
end
