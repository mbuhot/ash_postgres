# SPDX-FileCopyrightText: 2019 ash_postgres contributors <https://github.com/ash-project/ash_postgres/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshPostgres.TestRepo.Migrations.AddRoomBookings do
  @moduledoc """
  Hand-written migration for the temporal `room_bookings` table, keyed on a
  `tstzrange` period. Guarded to run only on PostgreSQL 19+ (where `WITHOUT
  OVERLAPS` is supported); a no-op otherwise, so it is safe on the older-Postgres
  CI matrix jobs (the `:postgres_19`-tagged temporal tests are excluded there).
  """
  use Ecto.Migration

  def up do
    if temporal_supported?() do
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
  end

  def down do
    if temporal_supported?() do
      execute("DROP TABLE room_bookings")
    end
  end

  defp temporal_supported? do
    %{rows: [[server_version_num]]} = repo().query!("SHOW server_version_num")
    String.to_integer(server_version_num) >= 190_000
  end
end
