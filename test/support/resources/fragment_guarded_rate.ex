# SPDX-FileCopyrightText: 2019 ash_postgres contributors <https://github.com/ash-project/ash_postgres/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshPostgres.Test.FragmentGuardedRate do
  @moduledoc """
  A temporal resource (entity key `code` + `owner`, `daterange` period `valid_at`) guarded by
  `Ash.Policy.Authorizer` with a FRAGMENT-based record-correlated policy for BOTH `:update` and
  `:destroy`.

  The policy is `authorize_if expr(fragment("? = ?", owner, ^actor(:owner)))`. A raw SQL
  fragment is opaque to Elixir, so `Ash.Policy.Authorizer` cannot STRICT-CHECK it in memory
  against the loaded record; it must be applied as a runtime DATA-LAYER FILTER (the
  `alter_source?`/`alter_query` path) — exactly the shape issue #21 describes. This exercises
  whether the `FOR PORTION OF` single-record clip threads that filter into `changeset.filter`
  and enforces it (via `filter_subquery/4`), or drops it.

  `:create` and `:read` are unguarded so a test can seed rows for, and read rows belonging to,
  any owner.

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
      authorize_if expr(fragment("? = ?", owner, ^actor(:owner)))
    end

    policy action_type(:destroy) do
      authorize_if expr(fragment("? = ?", owner, ^actor(:owner)))
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
