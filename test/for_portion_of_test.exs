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

    %{active_version("pro") | valid_at: {~D[2026-04-01], ~D[2026-07-01]}}
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
      {lower, upper} = booking.period
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

    %{active_booking("room-1") | period: {~U[2026-06-16 00:00:00Z], nil}}
    |> Ash.Changeset.for_destroy(:destroy)
    |> Ash.destroy!()

    assert bookings("room-1") == [
             {~U[2026-06-01 00:00:00Z], ~U[2026-06-16 00:00:00Z], "tentative"}
           ]
  end
end
