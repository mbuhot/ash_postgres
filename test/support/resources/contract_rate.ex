# SPDX-FileCopyrightText: 2019 ash_postgres contributors <https://github.com/ash-project/ash_postgres/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshPostgres.Test.ContractRate do
  @moduledoc """
  A temporal resource (entity key `code` + `daterange` period `valid_at`) carrying the
  scoping concerns the `FOR PORTION OF` rewrite must honour: attribute multitenancy on
  `owner`, an atomically-incremented `version`, and an action-level `filter`. Used to prove
  the rewrite threads `changeset.filter` into the mutation rather than dropping it.
  """
  use Ash.Resource,
    domain: AshPostgres.Test.Domain,
    data_layer: AshPostgres.DataLayer

  require Ash.Expr

  postgres do
    table "contract_rates"
    repo AshPostgres.TestRepo
    temporal_period :valid_at
    migrate? false

    check_constraints do
      check_constraint :monthly_price, "contract_rates_price_non_negative",
        check: "monthly_price >= 0",
        message: "must be non-negative"
    end
  end

  multitenancy do
    strategy :attribute
    attribute :owner
    global? true
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

    update :change_active_price do
      accept [:monthly_price, :valid_at]
      require_atomic? false

      change fn changeset, _ ->
        Ash.Changeset.filter(changeset, expr(active == true))
      end
    end

    update :bump_version do
      accept [:monthly_price, :valid_at]
      require_atomic? false
      change atomic_update(:version, expr(version + 1))
    end

    destroy :destroy

    destroy :destroy_active do
      require_atomic? false

      change fn changeset, _ ->
        Ash.Changeset.filter(changeset, expr(active == true))
      end
    end
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
