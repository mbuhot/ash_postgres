# SPDX-FileCopyrightText: 2019 ash_postgres contributors <https://github.com/ash-project/ash_postgres/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshPostgres.Test.ExclWidget do
  @moduledoc """
  A non-temporal resource whose table carries a GiST exclusion constraint that is NOT
  registered via `exclusion_constraint_names`. Used to pin the error contract for issue #24:
  an unconfigured exclusion violation on a non-temporal resource must keep surfacing as the
  prior `Ecto.ConstraintError`/`Ash.Error.Unknown`, not the temporal-only translated
  `Ash.Error.Changes.InvalidChanges`.
  """
  use Ash.Resource,
    domain: AshPostgres.Test.Domain,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "excl_widgets"
    repo AshPostgres.TestRepo
    migrate? false
  end

  actions do
    defaults [:read]

    create :create do
      accept [:bucket]
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :bucket, :integer, allow_nil?: false, public?: true
  end
end
