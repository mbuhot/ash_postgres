# SPDX-FileCopyrightText: 2019 ash_postgres contributors <https://github.com/ash-project/ash_postgres/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshPostgres.TemporalDetectionTest do
  @moduledoc """
  Temporal behaviour is opt-in via `temporal_period`, not inferred. A composite primary
  key that merely contains a range-typed member is an ordinary resource. No database
  needed — these assert the data layer's capability reporting.
  """
  use ExUnit.Case, async: true

  defmodule Declared do
    use Ash.Resource, domain: nil, validate_domain_inclusion?: false, data_layer: AshPostgres.DataLayer

    postgres do
      table("td_declared")
      repo(AshPostgres.TestRepo)
      temporal_period(:valid_at)
      migrate?(false)
    end

    attributes do
      attribute(:code, :string, primary_key?: true, allow_nil?: false, public?: true)

      attribute(:valid_at, AshPostgres.Test.DateRange,
        primary_key?: true,
        allow_nil?: false,
        public?: true
      )
    end
  end

  defmodule Undeclared do
    use Ash.Resource, domain: nil, validate_domain_inclusion?: false, data_layer: AshPostgres.DataLayer

    postgres do
      table("td_undeclared")
      repo(AshPostgres.TestRepo)
      migrate?(false)
    end

    attributes do
      attribute(:code, :string, primary_key?: true, allow_nil?: false, public?: true)

      attribute(:valid_at, AshPostgres.Test.DateRange,
        primary_key?: true,
        allow_nil?: false,
        public?: true
      )
    end
  end

  test "a declared temporal resource is routed off every query/many mutation path (so it can emit FOR PORTION OF)" do
    assert AshPostgres.DataLayer.Info.temporal_period(Declared) == :valid_at
    refute AshPostgres.DataLayer.can?(Declared, :update_query)
    refute AshPostgres.DataLayer.can?(Declared, :destroy_query)
    refute AshPostgres.DataLayer.can?(Declared, :update_many)
  end

  test "a composite PK with a range member but no temporal_period is an ordinary resource" do
    assert AshPostgres.DataLayer.Info.temporal_period(Undeclared) == nil
    assert AshPostgres.DataLayer.can?(Undeclared, :update_query)
    assert AshPostgres.DataLayer.can?(Undeclared, :destroy_query)
  end
end
