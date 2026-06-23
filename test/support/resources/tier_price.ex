# SPDX-FileCopyrightText: 2019 ash_postgres contributors <https://github.com/ash-project/ash_postgres/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshPostgres.Test.TierPrice do
  @moduledoc """
  An application-time temporal resource: its composite primary key pairs an entity
  key (`code`) with a `daterange` period (`valid_at`, declared `WITHOUT OVERLAPS` in
  the migration). An update/destroy that changes the period (`change_price` accepts
  `valid_at`, `require_atomic? false`) is rewritten by the data layer to a
  `FOR PORTION OF` clip; one that does not (`set_price` accepts only `monthly_price`)
  is an ordinary whole-row atomic `UPDATE`.
  """
  use Ash.Resource,
    domain: AshPostgres.Test.Domain,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "tier_prices"
    repo AshPostgres.TestRepo
    temporal_period :valid_at
    # The temporal DDL (WITHOUT OVERLAPS) is not expressible via the migration
    # generator, so the table is created by a hand-written migration.
    migrate? false
  end

  actions do
    defaults [:read]

    create :create do
      accept [:code, :valid_at, :monthly_price]
    end

    create :upsert_price do
      accept [:code, :valid_at, :monthly_price]
      upsert? true
    end

    update :change_price do
      accept [:monthly_price, :valid_at]
      require_atomic? false
    end

    update :set_price do
      accept [:monthly_price]
    end

    destroy :destroy
  end

  attributes do
    attribute :code, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :valid_at, AshPostgres.Test.DateRange, primary_key?: true, allow_nil?: false, public?: true
    attribute :monthly_price, :decimal, public?: true
  end
end
