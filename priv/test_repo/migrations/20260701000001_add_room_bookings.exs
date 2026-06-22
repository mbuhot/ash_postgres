# SPDX-FileCopyrightText: 2019 ash_postgres contributors <https://github.com/ash-project/ash_postgres/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshPostgres.TestRepo.Migrations.AddRoomBookings do
  @moduledoc """
  Hand-written migration for the temporal `room_bookings` table, keyed on a
  `tstzrange` period. Requires PostgreSQL 18+.
  """
  use Ecto.Migration

  def up do
    execute("CREATE EXTENSION IF NOT EXISTS btree_gist")

    execute("""
    CREATE TABLE room_bookings (
      room   text NOT NULL,
      period tstzrange NOT NULL,
      status text,
      PRIMARY KEY (room, period WITHOUT OVERLAPS)
    )
    """)
  end

  def down do
    execute("DROP TABLE room_bookings")
  end
end
