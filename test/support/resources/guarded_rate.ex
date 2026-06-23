# SPDX-FileCopyrightText: 2019 ash_postgres contributors <https://github.com/ash-project/ash_postgres/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshPostgres.Test.GuardedRate do
  @moduledoc """
  A temporal resource (entity key `code` + `owner`, `daterange` period `valid_at`) guarded by
  `Ash.Policy.Authorizer`, used to prove that policies gate the `FOR PORTION OF` mutation path.

  Update is authorized only for an actor whose `owner` matches the row's `owner`. That policy is
  a data-layer filter (`owner == ^actor(:owner)`) correlated to the period-row, so it proves the
  rewrite threads the policy filter into the mutation's entity-key `IN (<subquery>)` clause: a
  row owned by someone else is never clipped.

  Destroy is authorized only for an admin actor (`actor(:role) == :admin`), an actor-only check
  that resolves strictly, so an allowed actor's destroy clips the period-row and a non-admin's
  destroy is forbidden and leaves the row intact.

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
      authorize_if actor_attribute_equals(:role, :admin)
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
