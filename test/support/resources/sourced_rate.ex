# SPDX-FileCopyrightText: 2019 ash_postgres contributors <https://github.com/ash-project/ash_postgres/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshPostgres.Test.SourcedRate do
  @moduledoc """
  A temporal resource whose attributes carry `source:` column mappings: the entity
  key `code` stores to a mixed-case `"entityCode"` column and the `daterange` period
  `valid_at` stores to `"validPeriod"`. Used to prove the `FOR PORTION OF` rewrite
  emits storage column names, not attribute names, in every hand-built clause.
  """
  use Ash.Resource,
    domain: AshPostgres.Test.Domain,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "sourced_rates"
    repo AshPostgres.TestRepo
    temporal_period :valid_at
    migrate? false
  end

  actions do
    defaults [:read]

    create :create do
      accept [:code, :valid_at, :monthly_price]
    end

    update :change_price do
      accept [:monthly_price, :valid_at]
    end

    destroy :destroy
  end

  attributes do
    attribute :code, :string,
      primary_key?: true,
      allow_nil?: false,
      public?: true,
      source: :entityCode

    attribute :valid_at, AshPostgres.Test.DateRange,
      primary_key?: true,
      allow_nil?: false,
      public?: true,
      source: :validPeriod

    attribute :monthly_price, :decimal, public?: true, source: :monthlyPrice
  end
end
