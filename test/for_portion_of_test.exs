# SPDX-FileCopyrightText: 2019 ash_postgres contributors <https://github.com/ash-project/ash_postgres/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshPostgres.ForPortionOfTest do
  @moduledoc """
  When a resource's composite primary key includes a range-typed member (an
  application-time period), ordinary `update`/`destroy` actions are transparently
  rewritten to SQL:2011 `UPDATE/DELETE ... FOR PORTION OF`. PostgreSQL clips the
  matching rows to the written period and inserts any leftover remainder, so a single
  logical update/destroy can split one row into two.
  """
  use AshPostgres.RepoCase, async: false

  require Ash.Query

  alias AshPostgres.Test.TierPrice

  # FOR PORTION OF and WITHOUT OVERLAPS primary keys require PostgreSQL 18+.
  @moduletag :postgres_18

  defp create_price(code, price, from, to) do
    TierPrice
    |> Ash.Changeset.for_create(:create, %{
      code: code,
      monthly_price: Decimal.new(price),
      valid_at: {from, to}
    })
    |> Ash.create!()
  end

  defp active_version(code) do
    TierPrice
    |> Ash.Query.filter(code == ^code)
    |> Ash.read_one!()
  end

  defp versions(code) do
    TierPrice
    |> Ash.Query.filter(code == ^code)
    |> Ash.Query.sort(valid_at: :asc)
    |> Ash.read!()
    |> Enum.map(&{&1.valid_at, &1.monthly_price})
  end

  test "a plain update over a period splits the row into old- and new-value slices" do
    create_price("pro", "30.00", ~D[2026-01-01], nil)

    active_version("pro")
    |> Ash.Changeset.for_update(:change_price, %{
      monthly_price: Decimal.new("60.00"),
      valid_at: {~D[2026-06-16], nil}
    })
    |> Ash.update!()

    assert versions("pro") == [
             {{~D[2026-01-01], ~D[2026-06-16]}, Decimal.new("30.00")},
             {{~D[2026-06-16], nil}, Decimal.new("60.00")}
           ]
  end

  test "a plain destroy over a period clips the row, leaving the earlier portion" do
    create_price("pro", "30.00", ~D[2026-01-01], nil)

    %{active_version("pro") | valid_at: {~D[2026-06-16], nil}}
    |> Ash.Changeset.for_destroy(:destroy)
    |> Ash.destroy!()

    assert versions("pro") == [{{~D[2026-01-01], ~D[2026-06-16]}, Decimal.new("30.00")}]
  end
end
