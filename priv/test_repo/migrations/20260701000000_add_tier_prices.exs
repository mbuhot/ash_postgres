# SPDX-FileCopyrightText: 2019 ash_postgres contributors <https://github.com/ash-project/ash_postgres/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshPostgres.TestRepo.Migrations.AddTierPrices do
  @moduledoc """
  Hand-written migration for the temporal `tier_prices` table. The SQL:2011
  `PRIMARY KEY (code, valid_at WITHOUT OVERLAPS)` is not expressible via the Ash
  migration generator, so it is emitted directly. Requires PostgreSQL 18+.
  """
  use Ecto.Migration

  def up do
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

  def down do
    execute("DROP TABLE tier_prices")
  end
end
