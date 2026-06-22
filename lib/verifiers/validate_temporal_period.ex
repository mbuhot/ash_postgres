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
          "attribute `#{inspect(period)}` must have a range storage type " <>
            "(e.g. :daterange, :tstzrange), got #{inspect(storage_type(attribute))}"
        )

      primary_key == [period] ->
        error(
          dsl,
          "the primary key must include at least one member other than `#{inspect(period)}` " <>
            "to identify the entity across its timeline"
        )

      true ->
        maybe_warn_migrate(dsl, period)
    end
  end

  # The migration generator can't emit `WITHOUT OVERLAPS`, so a generated migration for a
  # temporal resource would be wrong. Steer the user to a hand-written migration.
  defp maybe_warn_migrate(dsl, period) do
    if Verifier.get_option(dsl, [:postgres], :migrate?) do
      {:warn,
       "`temporal_period #{inspect(period)}` is set with `migrate? true`, but the migration " <>
         "generator cannot emit a `WITHOUT OVERLAPS` primary key. Set `migrate? false` and " <>
         "hand-write the table's temporal DDL."}
    else
      :ok
    end
  end

  defp range_storage_type?(attribute) do
    case storage_type(attribute) do
      type when is_atom(type) -> String.ends_with?(to_string(type), "range")
      _ -> false
    end
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
