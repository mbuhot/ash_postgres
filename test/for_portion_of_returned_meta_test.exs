# SPDX-FileCopyrightText: 2019 ash_postgres contributors <https://github.com/ash-project/ash_postgres/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshPostgres.ForPortionOfReturnedMetaTest do
  @moduledoc """
  The single-record `FOR PORTION OF` update returns its clipped slice via
  `load_returned_records/4`, which must stamp the struct's Ecto metadata the same way
  the rest of the data layer does: `source` from `table(resource, changeset)` and
  `prefix` from `table_schema(resource, changeset)`. For a `:context` (schema)
  multitenant resource that means the returned record carries the tenant schema as its
  prefix rather than dropping it (issue #22).
  """
  use AshPostgres.RepoCase, async: false

  require Ash.Query

  alias AshPostgres.Test.TenantRate

  @moduletag :postgres_19

  setup do
    AshPostgres.TestRepo.query!("CREATE SCHEMA IF NOT EXISTS acme")

    AshPostgres.TestRepo.query!("""
    CREATE TABLE acme.tenant_rates (
      code          text NOT NULL,
      valid_at      daterange NOT NULL,
      monthly_price numeric,
      PRIMARY KEY (code, valid_at WITHOUT OVERLAPS)
    )
    """)

    :ok
  end

  test "a context-multitenant temporal update returns a record stamped with the tenant schema prefix" do
    TenantRate
    |> Ash.Changeset.for_create(
      :create,
      %{code: "pro", monthly_price: Decimal.new("30.00"), valid_at: {~D[2026-01-01], nil}},
      tenant: "acme"
    )
    |> Ash.create!()

    updated =
      TenantRate
      |> Ash.Query.filter(code == "pro")
      |> Ash.read_one!(tenant: "acme")
      |> Ash.Changeset.for_update(
        :change_price,
        %{monthly_price: Decimal.new("60.00"), valid_at: {~D[2026-06-16], nil}},
        tenant: "acme"
      )
      |> Ash.update!()

    assert updated.__meta__.source == "tenant_rates"
    assert updated.__meta__.prefix == "acme"
  end
end
