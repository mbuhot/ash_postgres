# SPDX-FileCopyrightText: 2019 ash_postgres contributors <https://github.com/ash-project/ash_postgres/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshPostgres.ForPortionOfVersionGuardTest do
  @moduledoc """
  `UPDATE/DELETE ... FOR PORTION OF` is a PostgreSQL 19 feature. When a temporal resource's
  repo declares a `min_pg_version` below 19, every `FOR PORTION OF` execution path must fail
  fast with a clear `Ash.Error` naming the requirement, rather than leaking a raw
  `Postgrex.Error` syntax failure from the server.
  """
  use AshPostgres.RepoCase, async: false

  require Ash.Query

  alias AshPostgres.Test.TierPrice

  @moduletag :postgres_19

  setup do
    previous = System.get_env("PG_VERSION")
    System.put_env("PG_VERSION", "18")
    on_exit(fn -> System.put_env("PG_VERSION", previous || "19") end)
    :ok
  end

  defp create_price(code, price, from, to) do
    System.put_env("PG_VERSION", "19")

    price =
      TierPrice
      |> Ash.Changeset.for_create(:create, %{
        code: code,
        monthly_price: Decimal.new(price),
        valid_at: {from, to}
      })
      |> Ash.create!()

    System.put_env("PG_VERSION", "18")
    price
  end

  defp active_version(code) do
    System.put_env("PG_VERSION", "19")

    price =
      TierPrice
      |> Ash.Query.filter(code == ^code)
      |> Ash.read_one!()

    System.put_env("PG_VERSION", "18")
    price
  end

  defp range({lower, upper}) do
    %Postgrex.Range{
      lower: lower || :unbound,
      lower_inclusive: true,
      upper: upper || :unbound,
      upper_inclusive: false
    }
  end

  defp assert_version_guard_error(result) do
    assert {:error, error} = result
    assert Ash.Error.ash_error?(error)
    refute is_struct(error, Postgrex.Error)
    assert Exception.message(error) =~ "PostgreSQL 19"
    assert Exception.message(error) =~ "FOR PORTION OF"
  end

  test "a temporal update on a repo below PostgreSQL 19 fails with a clear Ash error, not a Postgrex error" do
    create_price("pro", "30.00", ~D[2026-01-01], nil)

    active_version("pro")
    |> Ash.Changeset.for_update(:change_price, %{
      monthly_price: Decimal.new("60.00"),
      valid_at: {~D[2026-06-16], nil}
    })
    |> Ash.update()
    |> assert_version_guard_error()
  end

  test "a temporal destroy on a repo below PostgreSQL 19 fails with a clear Ash error, not a Postgrex error" do
    create_price("pro", "30.00", ~D[2026-01-01], nil)

    %{active_version("pro") | valid_at: range({~D[2026-06-16], nil})}
    |> Ash.Changeset.for_destroy(:destroy)
    |> Ash.destroy()
    |> assert_version_guard_error()
  end

  test "a temporal upsert on a repo below PostgreSQL 19 raises a clear Ash error, not a Postgrex error" do
    create_price("pro", "30.00", ~D[2026-01-01], nil)

    error =
      assert_raise Ash.Error.Unknown, fn ->
        TierPrice
        |> Ash.Changeset.for_create(:upsert_price, %{
          code: "pro",
          monthly_price: Decimal.new("99.00"),
          valid_at: {~D[2026-06-01], ~D[2026-09-01]}
        })
        |> Ash.create!()
      end

    refute is_struct(error, Postgrex.Error)
    assert Exception.message(error) =~ "PostgreSQL 19"
    assert Exception.message(error) =~ "FOR PORTION OF"
  end
end
