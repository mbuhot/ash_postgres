# SPDX-FileCopyrightText: 2019 ash_postgres contributors <https://github.com/ash-project/ash_postgres/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshPostgres.TestRepo.Migrations.AddContractRates do
  @moduledoc """
  Hand-written migration for the temporal `contract_rates` table used by the
  FOR PORTION OF filter-routing tests. The entity key spans `(owner, code)` so an
  attribute-multitenancy `owner` participates in the `WITHOUT OVERLAPS` primary key.
  Guarded to run only on PostgreSQL 19+ (where `WITHOUT OVERLAPS` is supported); a
  no-op otherwise, so it is safe on the older-Postgres CI matrix jobs (the
  `:postgres_19`-tagged temporal tests are excluded there).
  """
  use Ecto.Migration

  def up do
    if temporal_supported?() do
      execute("CREATE EXTENSION IF NOT EXISTS btree_gist")

      execute("""
      CREATE TABLE contract_rates (
        owner         text NOT NULL,
        code          text NOT NULL,
        valid_at      daterange NOT NULL,
        monthly_price numeric,
        active        boolean NOT NULL DEFAULT true,
        version       integer NOT NULL DEFAULT 1,
        PRIMARY KEY (owner, code, valid_at WITHOUT OVERLAPS),
        CONSTRAINT contract_rates_price_non_negative CHECK (monthly_price >= 0)
      )
      """)
    end
  end

  def down do
    if temporal_supported?() do
      execute("DROP TABLE contract_rates")
    end
  end

  defp temporal_supported? do
    %{rows: [[server_version_num]]} = repo().query!("SHOW server_version_num")
    String.to_integer(server_version_num) >= 190_000
  end
end
