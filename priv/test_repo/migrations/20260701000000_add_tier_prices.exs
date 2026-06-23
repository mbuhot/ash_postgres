# SPDX-FileCopyrightText: 2019 ash_postgres contributors <https://github.com/ash-project/ash_postgres/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshPostgres.TestRepo.Migrations.AddTierPrices do
  @moduledoc """
  Hand-written migration for the temporal `tier_prices` table. The SQL:2011
  `PRIMARY KEY (code, valid_at WITHOUT OVERLAPS)` is not expressible via the Ash
  migration generator, so it is emitted directly. Guarded to run only on
  PostgreSQL 19+ (where `WITHOUT OVERLAPS` is supported); a no-op otherwise, so it
  is safe on the older-Postgres CI matrix jobs (the `:postgres_19`-tagged temporal
  tests are excluded there anyway).
  """
  use Ecto.Migration

  def up do
    if temporal_supported?() do
      execute("CREATE EXTENSION IF NOT EXISTS btree_gist")

      execute("""
      CREATE TABLE tier_prices (
        code          text NOT NULL,
        valid_at      daterange NOT NULL,
        monthly_price numeric,
        PRIMARY KEY (code, valid_at WITHOUT OVERLAPS)
      )
      """)
    end
  end

  def down do
    if temporal_supported?() do
      execute("DROP TABLE tier_prices")
    end
  end

  defp temporal_supported? do
    %{rows: [[server_version_num]]} = repo().query!("SHOW server_version_num")
    String.to_integer(server_version_num) >= 190_000
  end
end
