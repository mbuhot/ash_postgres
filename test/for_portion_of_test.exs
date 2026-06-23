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

  alias AshPostgres.Test.RoomBooking
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
    |> Enum.map(&{to_bounds(&1.valid_at), &1.monthly_price})
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

  test "an update that does not change the period is a whole-row atomic UPDATE, not a FOR PORTION OF clip" do
    create_price("pro", "30.00", ~D[2026-01-01], nil)

    updated =
      active_version("pro")
      |> Ash.Changeset.for_update(:set_price, %{monthly_price: Decimal.new("45.00")})
      |> Ash.update!()

    assert to_bounds(updated.valid_at) == {~D[2026-01-01], nil}
    assert updated.monthly_price == Decimal.new("45.00")

    assert versions("pro") == [{{~D[2026-01-01], nil}, Decimal.new("45.00")}]
  end

  test "a whole-row update runs atomically (require_atomic? true) without raising MustBeAtomic" do
    create_price("pro", "30.00", ~D[2026-01-01], nil)

    assert true == Ash.Resource.Info.action(TierPrice, :set_price).require_atomic?

    active_version("pro")
    |> Ash.Changeset.for_update(:set_price, %{monthly_price: Decimal.new("45.00")})
    |> Ash.update!()

    assert versions("pro") == [{{~D[2026-01-01], nil}, Decimal.new("45.00")}]
  end

  defp capture_update_sql(fun) do
    test_pid = self()
    handler_id = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler_id,
      [:ash_postgres, :test_repo, :query],
      fn _event, _measurements, %{query: query}, _config ->
        if query =~ "UPDATE", do: send(test_pid, {:sql, query})
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler_id)
    end

    collect_sql([])
  end

  defp collect_sql(acc) do
    receive do
      {:sql, query} -> collect_sql([query | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "a whole-row update emits a plain UPDATE while a clip emits FOR PORTION OF" do
    create_price("pro", "30.00", ~D[2026-01-01], nil)

    whole_row_sql =
      capture_update_sql(fn ->
        active_version("pro")
        |> Ash.Changeset.for_update(:set_price, %{monthly_price: Decimal.new("45.00")})
        |> Ash.update!()
      end)

    assert Enum.any?(whole_row_sql, &(&1 =~ "UPDATE"))
    refute Enum.any?(whole_row_sql, &(&1 =~ "FOR PORTION OF"))

    clip_sql =
      capture_update_sql(fn ->
        active_version("pro")
        |> Ash.Changeset.for_update(:change_price, %{
          monthly_price: Decimal.new("60.00"),
          valid_at: {~D[2026-06-16], nil}
        })
        |> Ash.update!()
      end)

    assert Enum.any?(clip_sql, &(&1 =~ "FOR PORTION OF"))
  end

  test "a plain destroy over a period clips the row, leaving the earlier portion" do
    create_price("pro", "30.00", ~D[2026-01-01], nil)

    %{active_version("pro") | valid_at: range({~D[2026-06-16], nil})}
    |> Ash.Changeset.for_destroy(:destroy)
    |> Ash.destroy!()

    assert versions("pro") == [{{~D[2026-01-01], ~D[2026-06-16]}, Decimal.new("30.00")}]
  end

  test "an update over a bounded interior portion splits the row three ways" do
    create_price("pro", "30.00", ~D[2026-01-01], ~D[2027-01-01])

    active_version("pro")
    |> Ash.Changeset.for_update(:change_price, %{
      monthly_price: Decimal.new("60.00"),
      valid_at: {~D[2026-04-01], ~D[2026-07-01]}
    })
    |> Ash.update!()

    assert versions("pro") == [
             {{~D[2026-01-01], ~D[2026-04-01]}, Decimal.new("30.00")},
             {{~D[2026-04-01], ~D[2026-07-01]}, Decimal.new("60.00")},
             {{~D[2026-07-01], ~D[2027-01-01]}, Decimal.new("30.00")}
           ]
  end

  test "a destroy over a bounded interior portion leaves the two remainders with a gap" do
    create_price("pro", "30.00", ~D[2026-01-01], ~D[2027-01-01])

    %{active_version("pro") | valid_at: range({~D[2026-04-01], ~D[2026-07-01]})}
    |> Ash.Changeset.for_destroy(:destroy)
    |> Ash.destroy!()

    assert versions("pro") == [
             {{~D[2026-01-01], ~D[2026-04-01]}, Decimal.new("30.00")},
             {{~D[2026-07-01], ~D[2027-01-01]}, Decimal.new("30.00")}
           ]
  end

  test "clipping a sub-portion of one period-row leaves sibling rows untouched" do
    create_price("pro", "10.00", ~D[2026-01-01], ~D[2026-04-01])
    create_price("pro", "20.00", ~D[2026-04-01], ~D[2026-07-01])
    create_price("pro", "30.00", ~D[2026-07-01], nil)

    TierPrice
    |> Ash.Query.filter(code == "pro")
    |> Ash.Query.filter(valid_at == ^{~D[2026-04-01], ~D[2026-07-01]})
    |> Ash.read_one!()
    |> Ash.Changeset.for_update(:change_price, %{
      monthly_price: Decimal.new("25.00"),
      valid_at: {~D[2026-05-01], ~D[2026-06-01]}
    })
    |> Ash.update!()

    assert versions("pro") == [
             {{~D[2026-01-01], ~D[2026-04-01]}, Decimal.new("10.00")},
             {{~D[2026-04-01], ~D[2026-05-01]}, Decimal.new("20.00")},
             {{~D[2026-05-01], ~D[2026-06-01]}, Decimal.new("25.00")},
             {{~D[2026-06-01], ~D[2026-07-01]}, Decimal.new("20.00")},
             {{~D[2026-07-01], nil}, Decimal.new("30.00")}
           ]
  end

  test "an update spanning multiple rows returns the slice whose date lower bound equals the asserted from" do
    create_price("pro", "100.00", ~D[2020-01-01], ~D[2025-01-01])
    create_price("pro", "200.00", ~D[2025-01-01], nil)

    snapshot =
      TierPrice
      |> Ash.Query.filter(code == "pro")
      |> Ash.Query.filter(valid_at == ^{~D[2020-01-01], ~D[2025-01-01]})
      |> Ash.read_one!()

    updated =
      snapshot
      |> Ash.Changeset.for_update(:change_price, %{
        monthly_price: Decimal.new("555.00"),
        valid_at: {~D[2023-12-31], ~D[2027-06-15]}
      })
      |> Ash.update!()

    assert to_bounds(updated.valid_at) == {~D[2023-12-31], ~D[2025-01-01]}
    assert updated.monthly_price == Decimal.new("555.00")

    assert versions("pro") == [
             {{~D[2020-01-01], ~D[2023-12-31]}, Decimal.new("100.00")},
             {{~D[2023-12-31], ~D[2025-01-01]}, Decimal.new("555.00")},
             {{~D[2025-01-01], ~D[2027-06-15]}, Decimal.new("555.00")},
             {{~D[2027-06-15], nil}, Decimal.new("200.00")}
           ]
  end

  defp create_booking(room, status, from, to) do
    RoomBooking
    |> Ash.Changeset.for_create(:create, %{room: room, status: status, period: {from, to}})
    |> Ash.create!()
  end

  defp active_booking(room) do
    RoomBooking
    |> Ash.Query.filter(room == ^room)
    |> Ash.read_one!()
  end

  defp bookings(room) do
    RoomBooking
    |> Ash.Query.filter(room == ^room)
    |> Ash.Query.sort(period: :asc)
    |> Ash.read!()
    |> Enum.map(fn booking ->
      {lower, upper} = to_bounds(booking.period)
      {to_second(lower), to_second(upper), booking.status}
    end)
  end

  defp to_second(nil), do: nil
  defp to_second(%DateTime{} = datetime), do: DateTime.truncate(datetime, :second)

  test "tstzrange period: a plain update splits the booking into old- and new-status slices" do
    create_booking("room-1", "tentative", ~U[2026-06-01 00:00:00Z], nil)

    active_booking("room-1")
    |> Ash.Changeset.for_update(:rebook, %{
      status: "confirmed",
      period: {~U[2026-06-16 00:00:00Z], nil}
    })
    |> Ash.update!()

    assert bookings("room-1") == [
             {~U[2026-06-01 00:00:00Z], ~U[2026-06-16 00:00:00Z], "tentative"},
             {~U[2026-06-16 00:00:00Z], nil, "confirmed"}
           ]
  end

  test "tstzrange period: a plain destroy clips the booking, leaving the earlier portion" do
    create_booking("room-1", "tentative", ~U[2026-06-01 00:00:00Z], nil)

    %{active_booking("room-1") | period: range({~U[2026-06-16 00:00:00Z], nil})}
    |> Ash.Changeset.for_destroy(:destroy)
    |> Ash.destroy!()

    assert bookings("room-1") == [
             {~U[2026-06-01 00:00:00Z], ~U[2026-06-16 00:00:00Z], "tentative"}
           ]
  end
end
