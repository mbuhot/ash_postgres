# SPDX-FileCopyrightText: 2019 ash_postgres contributors <https://github.com/ash-project/ash_postgres/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshPostgres.TemporalPeriodVerifierTest do
  @moduledoc """
  The `temporal_period` option must name a range-typed primary-key attribute and leave at
  least one other primary-key member as the entity key. These are compile-time checks, so
  they need no database and run on the default CI matrix.
  """
  use ExUnit.Case, async: false

  import Spark.Test

  test "a valid declaration compiles" do
    refute_dsl_errors do
      defmodule TpValid do
        use Ash.Resource,
          domain: nil,
          validate_domain_inclusion?: false,
          data_layer: AshPostgres.DataLayer

        postgres do
          table("tp_valid")
          repo(AshPostgres.TestRepo)
          temporal_period(:valid_at)
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
    end
  end

  test "rejects a period that is not an attribute" do
    error =
      assert_dsl_error do
        defmodule TpMissing do
          use Ash.Resource,
            domain: nil,
            validate_domain_inclusion?: false,
            data_layer: AshPostgres.DataLayer

          postgres do
            table("tp_missing")
            repo(AshPostgres.TestRepo)
            temporal_period(:nope)
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
      end

    assert error.message =~ "does not exist"
  end

  test "rejects a period that is not part of the primary key" do
    error =
      assert_dsl_error do
        defmodule TpNonPk do
          use Ash.Resource,
            domain: nil,
            validate_domain_inclusion?: false,
            data_layer: AshPostgres.DataLayer

          postgres do
            table("tp_non_pk")
            repo(AshPostgres.TestRepo)
            temporal_period(:window)
          end

          attributes do
            attribute(:code, :string, primary_key?: true, allow_nil?: false, public?: true)
            attribute(:other, :string, primary_key?: true, allow_nil?: false, public?: true)
            attribute(:window, AshPostgres.Test.DateRange, allow_nil?: false, public?: true)
          end
        end
      end

    assert error.message =~ "primary key"
  end

  test "rejects a period whose storage type is not a range" do
    error =
      assert_dsl_error do
        defmodule TpNonRange do
          use Ash.Resource,
            domain: nil,
            validate_domain_inclusion?: false,
            data_layer: AshPostgres.DataLayer

          postgres do
            table("tp_non_range")
            repo(AshPostgres.TestRepo)
            temporal_period(:code)
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
      end

    assert error.message =~ "range storage type"
  end

  test "rejects a period whose storage type is a multirange" do
    error =
      assert_dsl_error do
        defmodule TpMultiRange do
          use Ash.Resource,
            domain: nil,
            validate_domain_inclusion?: false,
            data_layer: AshPostgres.DataLayer

          postgres do
            table("tp_multi_range")
            repo(AshPostgres.TestRepo)
            temporal_period(:valid_at)
          end

          attributes do
            attribute(:code, :string, primary_key?: true, allow_nil?: false, public?: true)

            attribute(:valid_at, AshPostgres.Test.DateMultiRange,
              primary_key?: true,
              allow_nil?: false,
              public?: true
            )
          end
        end
      end

    assert error.message =~ "range storage type"
  end

  test "rejects a primary key with no entity-identifying member beyond the period" do
    error =
      assert_dsl_error do
        defmodule TpOnlyPeriod do
          use Ash.Resource,
            domain: nil,
            validate_domain_inclusion?: false,
            data_layer: AshPostgres.DataLayer

          postgres do
            table("tp_only_period")
            repo(AshPostgres.TestRepo)
            temporal_period(:valid_at)
          end

          attributes do
            attribute(:valid_at, AshPostgres.Test.DateRange,
              primary_key?: true,
              allow_nil?: false,
              public?: true
            )
          end
        end
      end

    assert error.message =~ "at least one member other than"
  end

  test "rejects an optimistic_lock update action on a temporal resource" do
    error =
      assert_dsl_error do
        defmodule TpOptimisticLock do
          use Ash.Resource,
            domain: nil,
            validate_domain_inclusion?: false,
            data_layer: AshPostgres.DataLayer

          postgres do
            table("tp_optimistic_lock")
            repo(AshPostgres.TestRepo)
            temporal_period(:valid_at)
            migrate?(false)
          end

          actions do
            defaults([:read])

            update :change_price do
              accept([:monthly_price, :valid_at])
              change(optimistic_lock(:version))
            end
          end

          attributes do
            attribute(:code, :string, primary_key?: true, allow_nil?: false, public?: true)

            attribute(:valid_at, AshPostgres.Test.DateRange,
              primary_key?: true,
              allow_nil?: false,
              public?: true
            )

            attribute(:monthly_price, :decimal, public?: true)
            attribute(:version, :integer, allow_nil?: false, default: 1, public?: true)
          end
        end
      end

    assert error.message =~ "optimistic_lock"
  end

  test "compiles when migrate? true and the repo installs btree_gist" do
    refute_dsl_errors do
      defmodule TpMigratableWithBtreeGist do
        use Ash.Resource,
          domain: nil,
          validate_domain_inclusion?: false,
          data_layer: AshPostgres.DataLayer

        postgres do
          table("tp_migratable_with_btree_gist")
          repo(AshPostgres.TestRepo)
          temporal_period(:valid_at)
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
    end
  end

  test "rejects migrate? true when the repo does not install btree_gist" do
    previous = Application.get_env(:ash_postgres, :no_extensions, [])
    Application.put_env(:ash_postgres, :no_extensions, ["btree_gist" | previous])
    on_exit(fn -> Application.put_env(:ash_postgres, :no_extensions, previous) end)

    error =
      assert_dsl_error do
        defmodule TpMissingBtreeGist do
          use Ash.Resource,
            domain: nil,
            validate_domain_inclusion?: false,
            data_layer: AshPostgres.DataLayer

          postgres do
            table("tp_missing_btree_gist")
            repo(AshPostgres.TestRepo)
            temporal_period(:valid_at)
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
      end

    assert error.message =~ "btree_gist"
  end
end
