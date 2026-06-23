# SPDX-FileCopyrightText: 2019 ash_postgres contributors <https://github.com/ash-project/ash_postgres/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshPostgres.ForPortionOfPeriodTypeTest do
  @moduledoc """
  The data layer's runtime contract (issue #32) is that a temporal period attribute
  must materialize as a `%Postgrex.Range{}` after `cast_input`/`cast_stored`. The
  compile-time verifier only checks the storage type, so a type that stores as a range
  but casts to some other shape passes verification and only fails when a period-changing
  mutation reaches `period_bounds`. That failure must be a clear `Ash.Error` naming the
  contract, not a raw `FunctionClauseError`.
  """
  use AshPostgres.RepoCase, async: false

  require Ash.Query

  alias AshPostgres.Test.NonCanonicalTierPrice
  alias AshPostgres.Test.TierPrice

  @moduletag :postgres_19

  defp seed_well_behaved_row do
    TierPrice
    |> Ash.Changeset.for_create(:create, %{
      code: "pro",
      monthly_price: Decimal.new("30.00"),
      valid_at: {~D[2026-01-01], nil}
    })
    |> Ash.create!()
  end

  defp non_canonical_version(code) do
    NonCanonicalTierPrice
    |> Ash.Query.filter(code == ^code)
    |> Ash.read_one!()
  end

  test "a period-changing update with a non-%Postgrex.Range{} period value fails with a clear Ash error, not a FunctionClauseError" do
    seed_well_behaved_row()

    record = non_canonical_version("pro")

    error =
      assert_raise Ash.Error.Unknown, fn ->
        record
        |> Ash.Changeset.for_update(:change_price, %{
          monthly_price: Decimal.new("60.00"),
          valid_at: {~D[2026-06-16], nil}
        })
        |> Ash.update!()
      end

    assert Ash.Error.ash_error?(error)
    refute is_struct(error, FunctionClauseError)
    assert Exception.message(error) =~ "%Postgrex.Range{}"
  end
end
