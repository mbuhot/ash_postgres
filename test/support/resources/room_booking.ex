# SPDX-FileCopyrightText: 2019 ash_postgres contributors <https://github.com/ash-project/ash_postgres/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshPostgres.Test.RoomBooking do
  @moduledoc """
  A temporal resource keyed on a `tstzrange` period (`period`) rather than a
  `daterange`, to confirm the `FOR PORTION OF` rewrite is independent of the range
  subtype. Composite primary key `(room, period WITHOUT OVERLAPS)`.
  """
  use Ash.Resource,
    domain: AshPostgres.Test.Domain,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "room_bookings"
    repo AshPostgres.TestRepo
    temporal_period :period
    migrate? false
  end

  actions do
    defaults [:read]

    create :create do
      accept [:room, :period, :status]
    end

    update :rebook do
      accept [:status, :period]
      require_atomic? false
    end

    destroy :destroy
  end

  attributes do
    attribute :room, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :period, AshPostgres.Test.DateTimeRange, primary_key?: true, allow_nil?: false, public?: true
    attribute :status, :string, public?: true
  end
end
