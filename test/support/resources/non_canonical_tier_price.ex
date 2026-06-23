# SPDX-FileCopyrightText: 2019 ash_postgres contributors <https://github.com/ash-project/ash_postgres/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshPostgres.Test.NonCanonicalTierPrice do
  @moduledoc """
  Maps the same `tier_prices` table as `AshPostgres.Test.TierPrice`, but types its
  period (`valid_at`) with `AshPostgres.Test.NonCanonicalDateRange`, whose runtime
  value is a `{lower, upper}` tuple rather than a `%Postgrex.Range{}`. It exists to
  exercise issue #32: the storage type still passes the temporal verifier, but a
  period-changing update reaches `period_bounds` with a non-range value.
  """
  use Ash.Resource,
    domain: AshPostgres.Test.Domain,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "tier_prices"
    repo AshPostgres.TestRepo
    temporal_period :valid_at
    migrate? false
  end

  actions do
    defaults [:read]

    update :change_price do
      accept [:monthly_price, :valid_at]
      require_atomic? false
    end
  end

  attributes do
    attribute :code, :string, primary_key?: true, allow_nil?: false, public?: true

    attribute :valid_at, AshPostgres.Test.NonCanonicalDateRange,
      primary_key?: true,
      allow_nil?: false,
      public?: true

    attribute :monthly_price, :decimal, public?: true
  end
end
