# SPDX-FileCopyrightText: 2019 ash_postgres contributors <https://github.com/ash-project/ash_postgres/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshPostgres.Test.TenantRate do
  @moduledoc """
  A temporal resource (entity key `code` + `daterange` period `valid_at`) using
  schema-based (`:context`) multitenancy. Used to prove the `FOR PORTION OF` rewrite
  schema-qualifies both the mutation target and its entity-key `IN (<subquery>)` to
  the tenant's schema, so the statement never targets the default schema.
  """
  use Ash.Resource,
    domain: AshPostgres.Test.Domain,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "tenant_rates"
    repo AshPostgres.TestRepo
    temporal_period :valid_at
    migrate? false
  end

  multitenancy do
    strategy :context
  end

  actions do
    defaults [:read]

    create :create do
      accept [:code, :valid_at, :monthly_price]
    end

    update :change_price do
      accept [:monthly_price, :valid_at]
      require_atomic? false
    end

    destroy :destroy
  end

  attributes do
    attribute :code, :string, primary_key?: true, allow_nil?: false, public?: true

    attribute :valid_at, AshPostgres.Test.DateRange,
      primary_key?: true,
      allow_nil?: false,
      public?: true

    attribute :monthly_price, :decimal, public?: true
  end
end
