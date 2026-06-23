# SPDX-FileCopyrightText: 2019 ash_postgres contributors <https://github.com/ash-project/ash_postgres/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshPostgres.Test.OwnerGuardedRate do
  @moduledoc """
  A temporal resource (entity key `code` + `owner`, `daterange` period `valid_at`) guarded by
  `Ash.Policy.Authorizer` with a record-correlated filter policy (`owner == ^actor(:owner)`)
  for BOTH `:update` and `:destroy`.

  This differs from `GuardedRate`, whose destroy policy is an actor-only admin check: here the
  destroy decision depends on the targeted period-row's own `owner`, so it exercises whether the
  data layer threads the authorized query into the `FOR PORTION OF` destroy rewrite. `:create`
  and `:read` are unguarded so a test can seed rows for, and read rows belonging to, any owner.

  Shares the `contract_rates` table; no own migration.
  """
  use Ash.Resource,
    domain: AshPostgres.Test.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  require Ash.Expr

  postgres do
    table "contract_rates"
    repo AshPostgres.TestRepo
    temporal_period :valid_at
    migrate? false
  end

  policies do
    policy action_type([:create, :read]) do
      authorize_if always()
    end

    policy action_type(:update) do
      authorize_if expr(owner == ^actor(:owner))
    end

    policy action_type(:destroy) do
      authorize_if expr(owner == ^actor(:owner))
    end
  end

  actions do
    defaults [:read]

    create :create do
      accept [:code, :valid_at, :monthly_price, :owner, :active, :version]
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

    attribute :owner, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :monthly_price, :decimal, public?: true
    attribute :active, :boolean, allow_nil?: false, default: true, public?: true
    attribute :version, :integer, allow_nil?: false, default: 1, public?: true
  end
end
