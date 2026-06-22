# SPDX-FileCopyrightText: 2019 ash_postgres contributors <https://github.com/ash-project/ash_postgres/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshPostgres.Verifiers.ValidateTemporalPeriod do
  @moduledoc false
  use Spark.Dsl.Verifier
  alias Spark.Dsl.Verifier

  def verify(dsl) do
    case Verifier.get_option(dsl, [:postgres], :temporal_period) do
      nil -> :ok
      period -> validate(dsl, period)
    end
  end

  defp validate(dsl, period) do
    attributes = Verifier.get_entities(dsl, [:attributes])
    attribute = Enum.find(attributes, &(&1.name == period))
    primary_key = attributes |> Enum.filter(& &1.primary_key?) |> Enum.map(& &1.name)

    cond do
      is_nil(attribute) ->
        error(dsl, "names attribute `#{inspect(period)}`, which does not exist on the resource")

      period not in primary_key ->
        error(dsl, "attribute `#{inspect(period)}` must be part of the primary key")

      not range_storage_type?(attribute) ->
        error(
          dsl,
          "attribute `#{inspect(period)}` must have one of the built-in PostgreSQL range " <>
            "storage types (:daterange, :tsrange, :tstzrange, :int4range, :int8range, " <>
            ":numrange), got #{inspect(storage_type(attribute))} — custom and multirange " <>
            "types are not supported as temporal periods"
        )

      primary_key == [period] ->
        error(
          dsl,
          "the primary key must include at least one member other than `#{inspect(period)}` " <>
            "to identify the entity across its timeline"
        )

      true ->
        validate_btree_gist(dsl, period)
    end
  end

  # The generated `WITHOUT OVERLAPS` primary key is backed by a GiST exclusion constraint,
  # which requires the `btree_gist` extension. When the resource is migratable, the repo must
  # list `"btree_gist"` in `installed_extensions/0` so the extensions migration installs it.
  defp validate_btree_gist(dsl, period) do
    if Verifier.get_option(dsl, [:postgres], :migrate?) && !btree_gist_installed?(dsl) do
      error(
        dsl,
        "`temporal_period #{inspect(period)}` requires the `btree_gist` PostgreSQL extension " <>
          "for its `WITHOUT OVERLAPS` primary key. Add `\"btree_gist\"` to your repo's " <>
          "`installed_extensions/0`, or set `migrate? false` to manage the table's DDL yourself"
      )
    else
      :ok
    end
  end

  # The repo can be configured as a function `(resource, type) -> repo`, in which case its
  # extensions cannot be determined statically; only enforce the requirement for a plain repo
  # module that exports `installed_extensions/0`.
  defp btree_gist_installed?(dsl) do
    repo = Verifier.get_option(dsl, [:postgres], :repo)

    if is_atom(repo) && Code.ensure_loaded?(repo) &&
         function_exported?(repo, :installed_extensions, 0) do
      "btree_gist" in repo.installed_extensions()
    else
      true
    end
  end

  defp range_storage_type?(attribute) do
    match?({:ok, _}, AshPostgres.Temporal.RangeSubtype.cast_subtype(storage_type(attribute)))
  end

  defp storage_type(attribute), do: Ash.Type.storage_type(attribute.type, attribute.constraints)

  defp error(dsl, message) do
    raise Spark.Error.DslError,
      module: Verifier.get_persisted(dsl, :module),
      message: "Invalid `temporal_period`: #{message}.",
      path: [:postgres, :temporal_period],
      location: Spark.Dsl.Transformer.get_section_anno(dsl, [:postgres])
  end
end
