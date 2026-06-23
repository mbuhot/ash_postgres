# SPDX-FileCopyrightText: 2019 ash_postgres contributors <https://github.com/ash-project/ash_postgres/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshPostgres.ExclusionViolationGatingTest do
  @moduledoc """
  Issue #24: the temporal feature's exclusion-constraint translation is scoped to temporal
  resources. An unconfigured exclusion-constraint violation on a NON-temporal resource keeps its
  prior error contract — an `Ash.Error.Unknown` wrapping an `Ecto.ConstraintError` — rather than
  the temporal-only `Ash.Error.Changes.InvalidChanges`, so the temporal work does not silently
  change the error shape for existing non-temporal users.
  """
  use AshPostgres.RepoCase, async: false

  alias AshPostgres.Test.ExclWidget

  setup do
    AshPostgres.TestRepo.query!("CREATE EXTENSION IF NOT EXISTS btree_gist")

    AshPostgres.TestRepo.query!("""
    CREATE TABLE excl_widgets (
      id     uuid NOT NULL PRIMARY KEY,
      bucket integer NOT NULL,
      EXCLUDE USING gist (bucket WITH =)
    )
    """)

    :ok
  end

  test "an unconfigured exclusion violation on a non-temporal resource stays an Ash.Error.Unknown" do
    ExclWidget
    |> Ash.Changeset.for_create(:create, %{bucket: 1})
    |> Ash.create!()

    assert {:error, error} =
             ExclWidget
             |> Ash.Changeset.for_create(:create, %{bucket: 1})
             |> Ash.create()

    assert is_struct(error, Ash.Error.Unknown)
  end
end
