# SPDX-FileCopyrightText: 2019 ash_postgres contributors <https://github.com/ash-project/ash_postgres/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshPostgres.Test.DateMultiRange do
  @moduledoc """
  Minimal Ash type whose `storage_type/1` is `:datemultirange`. Multiranges have
  no scalar bounds, so they cannot back a `FOR PORTION OF` period and exist here
  only to prove the temporal period verifier rejects them.
  """
  use Ash.Type

  def storage_type(_), do: :datemultirange

  def cast_input(nil, _), do: {:ok, nil}
  def cast_input(value, _), do: {:ok, value}

  def cast_stored(nil, _), do: {:ok, nil}
  def cast_stored(value, _), do: {:ok, value}

  def dump_to_native(nil, _), do: {:ok, nil}
  def dump_to_native(value, _), do: {:ok, value}
end
