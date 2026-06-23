# SPDX-FileCopyrightText: 2019 ash_postgres contributors <https://github.com/ash-project/ash_postgres/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshPostgres.DataLayer.Temporal do
  @moduledoc false

  require Ecto.Query
  import Ecto.Query, only: [from: 2]

  # === SQL:2011 application-time temporal support ==========================
  #
  # A temporal resource is a timeline: the stored rows are non-overlapping period-rows for
  # one entity, and a loaded record is a snapshot of that timeline at a point. A resource
  # opts in by naming its period attribute with `temporal_period` in the `postgres` block
  # (validated by `AshPostgres.Verifiers.ValidateTemporalPeriod`: it must be a range-typed
  # primary-key member, with at least one other key member identifying the entity across its
  # timeline).
  #
  # A mutation asserts "these values for this period": the period attribute (`valid_at`) is
  # the asserted portion — defaulting to the snapshot's own period — and the other attribute
  # changes are the values to assert over it. Ordinary update/destroy operations are therefore
  # rewritten to `UPDATE/DELETE ... FOR PORTION OF`: PostgreSQL clips the matching period-rows
  # to the asserted portion and DB-side inserts any leftover remainder.
  #
  # The portion bounds come from the period attribute's value on the changeset (the change for
  # updates, the record for destroys); the SET clause is the other attribute changes; the WHERE
  # clause is the rest of the primary key (the entity key).

  @doc false
  def temporal_period_attribute(resource) do
    AshPostgres.DataLayer.Info.temporal_period(resource)
  end

  # The asserted portion of a temporal update is the period attribute's value on the changeset,
  # which defaults to the snapshot's own period. A changeset that *changes* the period asserts a
  # different portion than the row holds — a clip — and must be rewritten to `FOR PORTION OF`. A
  # changeset that leaves the period alone asserts the row's exact full period, which is an
  # ordinary whole-row `UPDATE` routed through the normal `do_update/2` path. Returns the period
  # attribute name when the resource is temporal and the changeset clips it, else nil.
  @doc false
  def temporal_clip_period(resource, changeset) do
    case temporal_period_attribute(resource) do
      nil -> nil
      period -> if Ash.Changeset.changing_attribute?(changeset, period), do: period
    end
  end

  # A period-changing temporal update is a clip: it must become a `FOR PORTION OF` statement,
  # not a plain `update_all` over the query's PK filter. Returns the `update_query/4`-shaped
  # result for a clip, or `:fallthrough` to run the normal atomic `UPDATE` (whole-row temporal
  # update or non-temporal resource).
  #
  # A single-record atomic update (the common per-record path, including the atomic upgrade of
  # one record) carries the loaded snapshot in `changeset.data`, so the clip is scoped to that
  # one entity via its entity key. A bulk atomic update (`Ash.bulk_update` over a query) has no
  # per-record snapshot (`changeset.data` is `OriginalDataNotAvailable`); its clip is scoped by
  # the bulk query's filter, which clips every matching period-row independently.
  @doc false
  def temporal_clip_query_update(query, resource, changeset, options) do
    case temporal_clip_period(resource, changeset) do
      nil ->
        :fallthrough

      period when is_struct(changeset.data, Ash.Changeset.OriginalDataNotAvailable) ->
        case for_portion_of_bulk_update(query, resource, changeset, period) do
          {:ok, records} -> if options[:return_records?], do: {:ok, records}, else: :ok
          other -> other
        end

      period ->
        case for_portion_of_update(resource, changeset, period) do
          {:ok, record} ->
            if options[:return_records?], do: {:ok, [record]}, else: :ok

          {:error, %Ash.Error.Changes.StaleRecord{}} ->
            if options[:return_records?], do: {:ok, []}, else: :ok

          other ->
            other
        end
    end
  end

  # A single-record temporal destroy carries the loaded snapshot in `changeset.data`, whose
  # period is the asserted portion: it is diverted to a `FOR PORTION OF` statement, which
  # handles a whole-row delete (the snapshot's full period) and a clip (a narrowed `valid_at`)
  # uniformly. A bulk/query destroy has no per-record snapshot (`changeset.data` is
  # `OriginalDataNotAvailable`) and never clips — it falls through to a plain atomic `DELETE`
  # of the whole rows matching the query.
  @doc false
  def temporal_clip_query_destroy(resource, changeset, options) do
    case temporal_period_attribute(resource) do
      nil ->
        :fallthrough

      _period when is_struct(changeset.data, Ash.Changeset.OriginalDataNotAvailable) ->
        :fallthrough

      period ->
        case for_portion_of_destroy(resource, changeset, period) do
          :ok ->
            if options[:return_records?], do: {:ok, [changeset.data]}, else: :ok

          {:error, %Ash.Error.Changes.StaleRecord{}} ->
            if options[:return_records?], do: {:ok, []}, else: :ok

          other ->
            other
        end
    end
  end

  @doc false
  def temporal_upsert(resource, changesets, source, repo, opts, options) do
    if !for_portion_of_supported?(repo) do
      raise for_portion_of_unsupported_error(repo)
    end

    period = temporal_period_attribute(resource)

    returning =
      if options.return_records? do
        resource
        |> Ash.Resource.Info.attributes()
        |> Enum.map(& &1.name)
      else
        nil
      end

    try do
      results =
        AshPostgres.DataLayer.with_savepoint(repo, savepoint_sentinel(), fn ->
          Enum.map(changesets, fn changeset ->
            temporal_upsert_one(resource, changeset, period, source, repo, opts, returning)
          end)
        end)

      if options.return_records? do
        {:ok, Enum.map(results, fn {record, changeset} -> tag_bulk_ref(record, changeset) end)}
      else
        :ok
      end
    rescue
      e ->
        changeset = Enum.at(changesets, 0)

        ecto_changeset =
          changeset.data
          |> case do
            %Ash.Changeset.OriginalDataNotAvailable{} -> changeset.resource.__struct__()
            data -> data
          end
          |> Map.update!(
            :__meta__,
            &Map.put(&1, :source, AshPostgres.DataLayer.table(resource, changeset))
          )
          |> AshPostgres.DataLayer.ecto_changeset(changeset, :create, repo, true)

        AshPostgres.DataLayer.handle_raised_error(
          e,
          __STACKTRACE__,
          {:ecto_changeset, :insert, ecto_changeset},
          resource
        )
    end
  end

  # Vacates the changeset's asserted period across the entity's overlapping rows, then inserts
  # the new period-row. The DELETE's portion is the changeset's period value; its WHERE is the
  # entity key (primary key minus the period), all sourced from `changeset.attributes` (a create
  # changeset has no `changeset.data`). Tenant scoping is honoured the same way the update/destroy
  # `FOR PORTION OF` paths do: the table is schema-qualified for `:context` multitenancy, and the
  # INSERT carries the tenant schema as its prefix.
  @doc false
  def temporal_upsert_one(resource, changeset, period, source, repo, opts, returning) do
    {vacate_sql, vacate_params} = build_temporal_vacate(resource, changeset, period)
    repo.query!(vacate_sql, vacate_params)

    insert_opts =
      if schema = changeset.context[:data_layer][:schema] do
        Keyword.put(opts, :prefix, schema)
      else
        opts
      end

    insert_opts =
      case returning do
        nil -> insert_opts
        fields -> Keyword.put(insert_opts, :returning, fields)
      end

    {_count, inserted} = repo.insert_all(source, [changeset.attributes], insert_opts)

    record =
      case inserted do
        [record | _] -> record
        _ -> nil
      end

    {record, changeset}
  end

  # Builds `DELETE FROM <table> FOR PORTION OF <period> FROM .. TO .. WHERE <entity key>` for a
  # temporal upsert, reading the asserted period and entity-key values from `changeset.attributes`
  # (a create changeset carries its values there, not in `changeset.data`).
  @doc false
  def build_temporal_vacate(resource, changeset, period) do
    {portion_sql, params} =
      period_bounds(Map.fetch!(changeset.attributes, period), subtype(resource, period), [])

    {where_sql, params} =
      identity_clause(resource, changeset.attributes, period, nil, params)

    statement =
      "DELETE FROM #{qualified_table(resource, changeset)} FOR PORTION OF #{quote_identifier(storage_name(resource, period))} #{portion_sql} " <>
        "WHERE #{where_sql}"

    {statement, params}
  end

  @doc false
  def tag_bulk_ref(nil, _changeset), do: nil

  @doc false
  def tag_bulk_ref(record, changeset) do
    Ash.Resource.put_metadata(record, :bulk_action_ref, changeset.context[:bulk_create][:ref])
  end

  # The FOR PORTION OF paths run hand-built `repo.query!` statements that bypass the query
  # pipeline, but must still execute inside a savepoint so a constraint violation rolls back
  # cleanly and translates to an `Ash.Error`. `with_savepoint/3` decides whether to open a
  # savepoint by reading `query.__ash_bindings__.expression_accumulator.has_error?`; there is no
  # real query here, so this is the minimal query-shaped value that forces that branch. Centralises
  # the fabricated shape so both call sites stay in sync with what `with_savepoint/3` matches on.
  @doc false
  def savepoint_sentinel do
    %{__ash_bindings__: %{expression_accumulator: %AshSql.Expr.ExprInfo{has_error?: true}}}
  end

  @doc false
  def for_portion_of_update(resource, changeset, period) do
    repo = AshSql.dynamic_repo(resource, AshPostgres.SqlImplementation, changeset)
    {statement, params, columns} = build_for_portion_of_update(resource, changeset, period, repo)

    case run_for_portion_of(repo, changeset, resource, :update, statement, params) do
      {:ok, result} ->
        case as_of_from_slice(load_returned_records(resource, changeset, columns, result), period) do
          nil ->
            {:error,
             Ash.Error.Changes.StaleRecord.exception(
               resource: resource,
               filter: changeset.filter
             )}

          record ->
            AshPostgres.DataLayer.maybe_update_tenant(resource, changeset, record)
            {:ok, record}
        end

      {:error, error} ->
        {:error, error}

      {:error, :no_rollback, error} ->
        {:error, :no_rollback, error}
    end
  end

  # A bulk atomic update clips every period-row matched by the bulk query, with no per-record
  # snapshot to scope an entity key by. The `FOR PORTION OF` statement's `WHERE` is therefore a
  # `(pk) IN (<bulk query>)` membership test, so PostgreSQL clips each matching row independently
  # — the same per-row clipping the streamed per-record path produces. Returns all resulting
  # slices (one per affected row) so `update_query/4` can hand back every record.
  @doc false
  def for_portion_of_bulk_update(query, resource, changeset, period) do
    repo = AshSql.dynamic_repo(resource, AshPostgres.SqlImplementation, changeset)

    {statement, params, columns} =
      build_for_portion_of_bulk_update(query, resource, changeset, period, repo)

    case run_for_portion_of(repo, changeset, resource, :update, statement, params) do
      {:ok, result} ->
        {:ok, load_returned_records(resource, changeset, columns, result)}

      {:error, error} ->
        {:error, error}

      {:error, :no_rollback, error} ->
        {:error, :no_rollback, error}
    end
  end

  @doc false
  def build_for_portion_of_bulk_update(query, resource, changeset, period, repo) do
    {where_sql, subquery_params} = bulk_membership_clause(query, resource, repo)

    {portion_sql, params} =
      period_bounds(
        Ash.Changeset.get_attribute(changeset, period),
        subtype(resource, period),
        subquery_params
      )

    {set_sql, params} = set_clause(resource, changeset, period, repo, params)

    {returning_sql, columns} = returning_clause(resource)

    statement =
      "UPDATE #{qualified_table(resource, changeset)} FOR PORTION OF #{quote_identifier(storage_name(resource, period))} #{portion_sql} " <>
        "SET #{set_sql} WHERE #{where_sql} RETURNING #{returning_sql}"

    {statement, params, columns}
  end

  # Renders the bulk query as a `(pk) IN (SELECT pk ... WHERE <bulk filter>)` membership clause,
  # so the `FOR PORTION OF` statement clips exactly the rows the bulk query selected.
  @doc false
  def bulk_membership_clause(query, resource, repo) do
    keys = Ash.Resource.Info.primary_key(resource)

    select_query =
      query
      |> Ecto.Query.exclude(:select)
      |> Ecto.Query.select([row], map(row, ^keys))
      |> Map.delete(:__ash_bindings__)

    {sql, params} = repo.to_sql(:all, select_query)

    columns = Enum.map_join(keys, ", ", &quote_identifier(storage_name(resource, &1)))

    {"(#{columns}) IN (#{sql})", params}
  end

  # Assembles the `UPDATE ... FOR PORTION OF ... RETURNING` statement and its ordered
  # parameter list. Parameter ordering is `subquery_params ++ [from, to] ++ entity_key_values
  # ++ set_params`, so the embedded filter subquery keeps its native `$1..$k`, the hand-built
  # clauses reference `$k+1 ...`, and the Ecto-rendered SET fragment's placeholders are shifted
  # to trail them all. Exposed for unit testing the (no-)filter SQL shape without a database
  # round trip.
  @doc false
  def build_for_portion_of_update(resource, changeset, period, repo) do
    {filter_sql, subquery_params} = filter_subquery(resource, changeset, period, repo)

    {portion_sql, params} =
      period_bounds(
        Ash.Changeset.get_attribute(changeset, period),
        subtype(resource, period),
        subquery_params
      )

    {where_sql, params} = identity_clause(resource, changeset.data, period, filter_sql, params)
    {set_sql, params} = set_clause(resource, changeset, period, repo, params)

    {returning_sql, columns} = returning_clause(resource)

    statement =
      "UPDATE #{qualified_table(resource, changeset)} FOR PORTION OF #{quote_identifier(storage_name(resource, period))} #{portion_sql} " <>
        "SET #{set_sql} WHERE #{where_sql} RETURNING #{returning_sql}"

    {statement, params, columns}
  end

  @doc false
  def for_portion_of_destroy(resource, changeset, period) do
    repo = AshSql.dynamic_repo(resource, AshPostgres.SqlImplementation, changeset)
    {statement, params} = build_for_portion_of_destroy(resource, changeset, period, repo)

    case run_for_portion_of(repo, changeset, resource, :delete, statement, params) do
      {:ok, %{num_rows: 0}} ->
        {:error,
         Ash.Error.Changes.StaleRecord.exception(
           resource: resource,
           filter: changeset.filter
         )}

      {:ok, _} ->
        :ok

      {:error, error} ->
        {:error, error}

      {:error, :no_rollback, error} ->
        {:error, :no_rollback, error}
    end
  end

  @doc false
  def build_for_portion_of_destroy(resource, changeset, period, repo) do
    {filter_sql, subquery_params} = filter_subquery(resource, changeset, period, repo)

    {portion_sql, params} =
      period_bounds(Map.get(changeset.data, period), subtype(resource, period), subquery_params)

    {where_sql, params} = identity_clause(resource, changeset.data, period, filter_sql, params)

    statement =
      "DELETE FROM #{qualified_table(resource, changeset)} FOR PORTION OF #{quote_identifier(storage_name(resource, period))} #{portion_sql} " <>
        "WHERE #{where_sql}"

    {statement, params}
  end

  # `UPDATE/DELETE ... FOR PORTION OF` is a PostgreSQL 19 feature (PG18 only adds the
  # `WITHOUT OVERLAPS` DDL). The temporal resources compile on any version, so support is
  # decided at runtime from the repo's declared `min_pg_version`, mirroring how `repo.ex`
  # branches on the major version for the builtin uuidv7 function.
  @doc false
  def for_portion_of_supported?(repo) do
    %Version{major: major} = repo.min_pg_version()
    major >= 19
  end

  # Builds the clear `Ash.Error` raised/returned when a `FOR PORTION OF` mutation is attempted
  # on a repo declaring a PostgreSQL version below 19, naming the requirement and the declared
  # version instead of leaking a raw `Postgrex.Error` syntax failure from the server.
  @doc false
  def for_portion_of_unsupported_error(repo) do
    declared = repo.min_pg_version()

    Ash.Error.to_ash_error(
      "FOR PORTION OF temporal mutations require PostgreSQL 19, but #{inspect(repo)} declares " <>
        "min_pg_version #{Version.to_string(declared)}. Upgrade the database to PostgreSQL >= 19."
    )
  end

  # Runs the hand-built FOR PORTION OF statement inside the same savepoint and error
  # translation the normal mutation paths use, so a WITHOUT OVERLAPS exclusion (or any
  # FK/check/not-null violation) surfaces as a translated `Ash.Error` rather than a raw
  # `Postgrex.Error`, and failure is savepoint-isolated.
  @doc false
  def run_for_portion_of(repo, changeset, resource, action, statement, params) do
    if for_portion_of_supported?(repo) do
      do_run_for_portion_of(repo, changeset, resource, action, statement, params)
    else
      {:error, for_portion_of_unsupported_error(repo)}
    end
  end

  @doc false
  def do_run_for_portion_of(repo, changeset, resource, action, statement, params) do
    ecto_changeset =
      case changeset.data do
        %Ash.Changeset.OriginalDataNotAvailable{} -> changeset.resource.__struct__()
        data -> data
      end
      |> Map.update!(
        :__meta__,
        &Map.put(&1, :source, AshPostgres.DataLayer.table(resource, changeset))
      )
      |> AshPostgres.DataLayer.ecto_changeset(changeset, action, repo, true)

    try do
      result =
        AshPostgres.DataLayer.with_savepoint(repo, savepoint_sentinel(), fn ->
          repo.query!(statement, params)
        end)

      {:ok, result}
    rescue
      e ->
        AshPostgres.DataLayer.handle_raised_error(
          e,
          __STACKTRACE__,
          {:ecto_changeset, action, ecto_changeset},
          resource
        )
    end
  end

  # Builds a `(<full primary key>) IN (<subquery>)` clause carrying `changeset.filter`
  # (policy/auth filters, base/soft-delete filters, and attribute-multitenancy scoping).
  # Reuses the data layer's own query builders so the filter is rendered exactly as the
  # standard `do_update`/`do_destroy` paths enforce it.
  #
  # The correlation key is the FULL primary key — including the period column — so the filter
  # is evaluated against the exact stored rows `FOR PORTION OF` will clip, not merely against
  # any period-row sharing the entity key. (A temporal entity holds many non-overlapping
  # period-rows; correlating on the entity key alone would let a sibling row satisfy the
  # filter while the clip lands on a non-matching row — a scope bypass.)
  #
  # Returns `{nil, []}` when there is no filter and no tenant scoping, so the clause is omitted.
  @doc false
  def filter_subquery(resource, changeset, _period, repo) do
    if filter_subquery_required?(changeset) do
      keys = Ash.Resource.Info.primary_key(resource)
      source = AshPostgres.DataLayer.resolve_source(resource, changeset)

      query =
        from(row in source, as: ^0)
        |> AshSql.Bindings.default_bindings(
          resource,
          AshPostgres.SqlImplementation,
          changeset.context
        )

      {:ok, query} = AshPostgres.DataLayer.filter(query, changeset.filter, resource)
      {:ok, query} = AshPostgres.DataLayer.set_tenant(resource, query, changeset.tenant)

      query =
        query
        |> Ecto.Query.select([row], map(row, ^keys))
        |> Map.delete(:__ash_bindings__)

      {sql, params} = repo.to_sql(:all, query)

      columns =
        Enum.map_join(keys, ", ", &quote_identifier(storage_name(resource, &1)))

      {"(#{columns}) IN (#{sql})", params}
    else
      {nil, []}
    end
  end

  @doc false
  def filter_subquery_required?(changeset) do
    not (empty_filter?(changeset.filter) and is_nil(changeset.tenant))
  end

  @doc false
  def empty_filter?(nil), do: true
  @doc false
  def empty_filter?(%Ash.Filter{expression: nil}), do: true
  @doc false
  def empty_filter?(_), do: false

  # Returns the `RETURNING` SQL (storage column names) alongside the attribute names in the
  # same order, so `load_returned_records/4` can zip each returned value back to its attribute.
  @doc false
  def returning_clause(resource) do
    attributes =
      resource
      |> Ash.Resource.Info.attributes()
      |> Enum.map(& &1.name)

    sql = Enum.map_join(attributes, ", ", &quote_identifier(storage_name(resource, &1)))

    {sql, attributes}
  end

  # A temporal update can clip several period-rows, so `RETURNING` yields one slice per affected
  # row in unspecified order. The snapshot to hand back is the earliest one — the as-of-`from`
  # slice (the clip starts at `from`, so the earliest returned slice is the one covering it).
  # Returns nil for 0 rows, which the caller surfaces as `StaleRecord`. The lower bounds are
  # compared *semantically* (`Date.compare/2` etc.): range subtypes do not order by Erlang term
  # order, so a positional/`min_by` sort would be wrong.
  @doc false
  def as_of_from_slice([], _period), do: nil

  @doc false
  def as_of_from_slice([first | rest], period) do
    Enum.reduce(rest, first, fn record, earliest ->
      if lower_before?(
           period_lower(Map.get(record, period)),
           period_lower(Map.get(earliest, period))
         ) do
        record
      else
        earliest
      end
    end)
  end

  @doc false
  def period_lower(%Postgrex.Range{lower: lower}), do: unbound_to_nil(lower)
  @doc false
  def period_lower(value), do: raise(non_range_period_error(value))

  # A temporal period attribute must materialize as a `%Postgrex.Range{}` at runtime, but the
  # compile-time verifier only checks the storage type. Surface a violation of that contract as a
  # clear `Ash.Error` instead of letting a `FunctionClauseError` escape.
  @doc false
  def non_range_period_error(value) do
    Ash.Error.to_ash_error(
      "Temporal period value #{inspect(value)} is not a %Postgrex.Range{}. A temporal_period " <>
        "attribute's type must cast and materialize to a %Postgrex.Range{} (with nil or :unbound " <>
        "for unbounded bounds) after cast_input/cast_stored."
    )
  end

  @doc false
  def unbound_to_nil(:unbound), do: nil
  @doc false
  def unbound_to_nil(value), do: value

  @doc false
  def lower_before?(nil, _other), do: true
  @doc false
  def lower_before?(_lower, nil), do: false
  @doc false
  def lower_before?(lower, other), do: compare_lower(lower, other) == :lt

  @doc false
  def compare_lower(%module{} = lower, %module{} = other)
      when module in [Date, DateTime, NaiveDateTime, Time],
      do: module.compare(lower, other)

  @doc false
  def compare_lower(%Decimal{} = lower, %Decimal{} = other), do: Decimal.compare(lower, other)
  @doc false
  def compare_lower(lower, other) when lower < other, do: :lt
  @doc false
  def compare_lower(lower, other) when lower > other, do: :gt
  @doc false
  def compare_lower(_lower, _other), do: :eq

  @doc false
  def load_returned_records(resource, changeset, columns, %{rows: rows}) do
    Enum.map(rows, fn row ->
      attrs =
        columns
        |> Enum.zip(row)
        |> Map.new(fn {column, value} ->
          attribute = Ash.Resource.Info.attribute(resource, column)
          {:ok, casted} = Ash.Type.cast_stored(attribute.type, value, attribute.constraints)
          {column, casted}
        end)

      resource
      |> struct(attrs)
      |> Map.put(:__meta__, %Ecto.Schema.Metadata{
        state: :loaded,
        source: AshPostgres.DataLayer.table(resource, changeset),
        prefix: table_schema(resource, changeset)
      })
    end)
  end

  # The storage (DB column) name for an attribute, honouring its `source:` mapping.
  @doc false
  def storage_name(resource, attribute_name) do
    Ash.Resource.Info.attribute(resource, attribute_name).source || attribute_name
  end

  @doc false
  def quote_identifier(name) do
    ~s(") <> String.replace(to_string(name), ~s("), ~s("")) <> ~s(")
  end

  @doc false
  def qualified_table(resource, changeset) do
    table = AshPostgres.DataLayer.table(resource, changeset)

    case table_schema(resource, changeset) do
      nil -> quote_identifier(table)
      schema -> "#{quote_identifier(schema)}.#{quote_identifier(table)}"
    end
  end

  @doc false
  def table_schema(resource, changeset) do
    if Ash.Resource.Info.multitenancy_strategy(resource) == :context && changeset.tenant do
      to_string(changeset.tenant)
    else
      AshPostgres.DataLayer.Info.schema(resource)
    end
  end

  # Reuse the data layer's own dumping: build the Ecto changeset a normal update would
  # use, whose `.changes` is the attribute => dumped-native-value map.
  @doc false
  def storage_changes(resource, changeset, repo) do
    case changeset.data do
      %Ash.Changeset.OriginalDataNotAvailable{} -> changeset.resource.__struct__()
      data -> data
    end
    |> Map.update!(
      :__meta__,
      &Map.put(&1, :source, AshPostgres.DataLayer.table(resource, changeset))
    )
    |> AshPostgres.DataLayer.ecto_changeset(changeset, :update, repo, true)
    |> Map.fetch!(:changes)
  end

  # The FROM/TO bounds need an explicit cast to the range's subtype: a bare parameter
  # in `FROM $1 TO NULL` is ambiguous to PostgreSQL.
  @doc false
  def period_bounds(%Postgrex.Range{lower: lower, upper: upper}, subtype, params) do
    lower = unbound_to_nil(lower)
    upper = unbound_to_nil(upper)
    params = params ++ [lower]
    from_sql = "FROM $#{length(params)}::#{subtype}"

    case upper do
      nil -> {"#{from_sql} TO NULL", params}
      _ -> {"#{from_sql} TO $#{length(params) + 1}::#{subtype}", params ++ [upper]}
    end
  end

  @doc false
  def period_bounds(value, _subtype, _params), do: raise(non_range_period_error(value))

  # Renders the SET clause — static attribute changes and `changeset.atomics` (e.g. an
  # `atomic_update`/counter expression) together — by reusing `AshSql.Atomics.query_with_atomics`,
  # the same renderer the ordinary (atomic) update path uses, then adapting its output for the
  # alias-free `FOR PORTION OF` statement.
  #
  # WORKAROUND: PostgreSQL does not permit a table alias on the target of an
  # `UPDATE ... FOR PORTION OF` (`UPDATE t AS x FOR PORTION OF ...` is a syntax error), but Ecto
  # always renders an UPDATE's SET with the source qualified (`x0."col"`). Because we cannot ask
  # Ecto for an unqualified render, we render normally via `to_sql/2` and then strip the
  # qualifier from the SET fragment. In an unaliased UPDATE the bare `"col"` already denotes the
  # matched row's current value, so `"col" = "col" + $n` is exactly the increment we want.
  #
  # The de-qualification is safe and deterministic:
  #   * `filter: nil` + no joins makes `to_sql(:update_all)` emit exactly
  #     `UPDATE <table> AS <alias> SET <frag>` with no trailing WHERE/FROM, so `<frag>` is the
  #     whole tail and the alias is the single `AS <alias>` token before ` SET `.
  #   * Params are `$n` placeholders (data is never inlined), so `<alias>.` only ever appears as
  #     a column qualifier — never inside a literal.
  #   * The fragment's native `$1..$m` are shifted past the params already accumulated, and its
  #     params appended last (the same positional-param composition `filter_subquery/4` uses).
  #
  # Only atomics over the resource's own columns are supported. Atomics referencing aggregates or
  # relationships make `query_with_atomics` emit joins/subqueries (with their own aliases) that
  # de-qualification would corrupt; those are detected and refused rather than mis-rendered.
  @doc false
  def set_clause(resource, changeset, period, repo, params) do
    changes = Map.delete(storage_changes(resource, changeset, repo), period)

    query =
      from(row in AshPostgres.DataLayer.resolve_source(resource, changeset), as: ^0)
      |> AshSql.Bindings.default_bindings(
        resource,
        AshPostgres.SqlImplementation,
        changeset.context
      )

    case AshSql.Atomics.query_with_atomics(resource, query, nil, changeset.atomics, changes, []) do
      {:empty, _query} ->
        raise ArgumentError,
              "temporal update for #{inspect(resource)} sets no attributes: a temporal write must " <>
                "set at least one non-period attribute. `#{period}` only selects the portion to " <>
                "assert values for, it is not itself an assertable value"

      {:ok, query} ->
        {sql, set_params} = repo.to_sql(:update_all, Map.delete(query, :__ash_bindings__))

        [header, fragment] = String.split(sql, " SET ", parts: 2)

        fragment = dequalify_set(fragment, header, resource)

        {shift_placeholders(fragment, length(params)), params ++ set_params}

      {:error, error} ->
        raise ArgumentError,
              "temporal update for #{inspect(resource)} could not render atomics into an " <>
                "alias-free SET clause (atomics referencing aggregates or relationships are " <>
                "unsupported): #{inspect(error)}"
    end
  end

  # Strips the table-source qualifier Ecto added (`<alias>.`) from a rendered SET fragment so it
  # is valid inside `FOR PORTION OF`. See `set_clause/5` for why this is required and safe.
  @doc false
  def dequalify_set(fragment, header, resource) do
    if String.contains?(fragment, [" FROM ", "(SELECT"]) do
      raise ArgumentError,
            "temporal update for #{inspect(resource)} renders a subquery/join in its SET clause " <>
              "(atomics referencing aggregates or relationships are unsupported in FOR PORTION OF)"
    end

    case Regex.run(~r/ AS (\w+)$/, header) do
      [_, source_alias] -> String.replace(fragment, source_alias <> ".", "")
      nil -> fragment
    end
  end

  @doc false
  def shift_placeholders(sql, 0), do: sql

  @doc false
  def shift_placeholders(sql, offset) do
    Regex.replace(~r/\$(\d+)/, sql, fn _, digits ->
      "$#{String.to_integer(digits) + offset}"
    end)
  end

  @doc false
  def identity_clause(resource, data, period, filter_sql, params) do
    fields = Ash.Resource.Info.primary_key(resource) -- [period]

    {fragments, params} =
      Enum.reduce(fields, {[], params}, fn field, {fragments, params} ->
        value = dump_attribute(resource, field, Map.get(data, field))
        column = quote_identifier(storage_name(resource, field))
        {fragments ++ ["#{column} = $#{length(params) + 1}"], params ++ [value]}
      end)

    fragments =
      case filter_sql do
        nil -> fragments
        sql -> fragments ++ [sql]
      end

    {Enum.join(fragments, " AND "), params}
  end

  @doc false
  def dump_attribute(resource, field, value) do
    attribute = Ash.Resource.Info.attribute(resource, field)
    {:ok, dumped} = Ash.Type.dump_to_native(attribute.type, value, attribute.constraints)
    dumped
  end

  @doc false
  def subtype(resource, period) do
    attribute = Ash.Resource.Info.attribute(resource, period)
    storage_type = Ash.Type.storage_type(attribute.type, attribute.constraints)

    case AshPostgres.Temporal.RangeSubtype.cast_subtype(storage_type) do
      {:ok, subtype} ->
        subtype

      :error ->
        raise ArgumentError,
              "temporal period `#{inspect(period)}` has storage type #{inspect(storage_type)}, " <>
                "which is not a supported range type. Only the built-in PostgreSQL range types " <>
                "(:daterange, :tsrange, :tstzrange, :int4range, :int8range, :numrange) are " <>
                "supported as temporal periods."
    end
  end
end
