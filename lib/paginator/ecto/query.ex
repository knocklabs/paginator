defmodule Paginator.Ecto.Query do
  @moduledoc false

  import Ecto.Query

  alias Paginator.Config
  alias Paginator.Ecto.Query.DynamicFilterBuilder

  def paginate(queryable, config \\ [])

  def paginate(queryable, %Config{} = config) do
    queryable
    |> maybe_where(config)
    |> limit(^query_limit(config))
  end

  def paginate(queryable, opts) do
    config = Config.new(opts)
    paginate(queryable, config)
  end

  # This clause is responsible for transforming legacy list cursors into map cursors
  defp filter_values(query, fields, values, query_fields, cursor_direction)
       when is_list(values) do
    new_values =
      fields
      |> Enum.map(&elem(&1, 0))
      |> Enum.zip(values)
      |> Map.new()

    filter_values(query, fields, new_values, query_fields, cursor_direction)
  end

  defp filter_values(query, fields, values, query_fields, cursor_direction) when is_map(values) do
    filters = build_where_expression(query, fields, values, query_fields, cursor_direction)

    where(query, [{q, 0}], ^filters)
  end

  defp build_where_expression(query, [{column, order}], values, query_fields, cursor_direction) do
    value = get_cursor_value(values, column)
    {q_position, q_binding} = column_position(query, column, query_fields)

    DynamicFilterBuilder.build!(%{
      sort_order: order,
      direction: cursor_direction,
      value: value,
      entity_position: q_position,
      column: q_binding,
      next_filters: true
    })
  end

  defp build_where_expression(
         query,
         [{column, order} | fields],
         values,
         query_fields,
         cursor_direction
       ) do
    value = get_cursor_value(values, column)
    {q_position, q_binding} = column_position(query, column, query_fields)

    filters = build_where_expression(query, fields, values, query_fields, cursor_direction)

    DynamicFilterBuilder.build!(%{
      sort_order: order,
      direction: cursor_direction,
      value: value,
      entity_position: q_position,
      column: q_binding,
      next_filters: filters
    })
  end

  defp get_cursor_value(cursor_values, column) do
    case cursor_values do
      %{cursor: %{^column => val}} -> val
      %{^column => val} -> val
      _ -> nil
    end
  end

  defp maybe_where(query, %Config{
         after: nil,
         before: nil
       }) do
    query
  end

  defp maybe_where(query, %Config{
         after_values: after_values,
         before: nil,
         cursor_fields: cursor_fields,
         query_field_for_cursor_field: query_field_for_cursor_field
       }) do
    query
    |> filter_values(cursor_fields, after_values, query_field_for_cursor_field, :after)
  end

  defp maybe_where(
         query,
         %Config{
           after: nil,
           before_values: before_values,
           cursor_fields: cursor_fields,
           use_seeking_cursors: use_seeking_cursors,
           query_field_for_cursor_field: query_field_for_cursor_field
         } = config
       ) do
    case {use_seeking_cursors, before_values} do
      # When using a complex seeking cursor, we provide an inclusive upper-bound on the
      # query so we do not need to invert the sort order to get the most recent N values
      # before a given cursor. We use the accumulated previous before-point as the upper-bound.
      {true, %{cursor: before_values, acc: %{before: %{cursor: prev_before_values}}}} ->
        query
        |> filter_values(
          cursor_fields,
          prev_before_values,
          query_field_for_cursor_field,
          :after_inclusive
        )
        |> filter_values(cursor_fields, before_values, query_field_for_cursor_field, :before)

      {_, before_values} ->
        query
        |> filter_values(cursor_fields, before_values, query_field_for_cursor_field, :before)
        |> maybe_reverse_order_bys(config)
    end
  end

  defp maybe_where(query, %Config{
         after_values: after_values,
         before_values: before_values,
         cursor_fields: cursor_fields,
         query_field_for_cursor_field: query_field_for_cursor_field
       }) do
    query
    |> filter_values(cursor_fields, after_values, query_field_for_cursor_field, :after)
    |> filter_values(cursor_fields, before_values, query_field_for_cursor_field, :before)
  end

  # Lookup position of binding in query aliases
  defp column_position(query, {binding_name, column}, _) do
    case Map.fetch(query.aliases, binding_name) do
      {:ok, position} ->
        {position, column}

      _ ->
        raise(
          ArgumentError,
          "Could not find binding `#{binding_name}` in query aliases: #{inspect(query.aliases)}"
        )
    end
  end

  defp column_position(query, column, query_fields)
       when is_atom(column) and is_map(query_fields) do
    with {:ok, {alias_binding, target_column}} <- Map.fetch(query_fields, column),
         {:ok, position} <- Map.fetch(query.aliases, alias_binding) do
      {position, target_column}
    else
      _ -> {0, column}
    end
  end

  # Without named binding we assume position of binding is 0
  defp column_position(_query, column, _), do: {0, column}

  #  In order to return the correct pagination cursors, we need to fetch one more
  # # record than we actually want to return.
  defp query_limit(%Config{limit: limit}) do
    limit + 1
  end

  # When using a seeking style cursor for a query, we don't invert the sort
  # order for an unbounded backwards pagination action
  defp maybe_reverse_order_bys(
         query,
         %Config{
           use_seeking_cursors: true,
           before_values: %{cursor: _, acc: _}
         }
       ) do
    query
  end

  # This code was taken from https://github.com/elixir-ecto/ecto/blob/v2.1.4/lib/ecto/query.ex#L1212-L1226
  defp maybe_reverse_order_bys(query, _) do
    update_in(query.order_bys, fn
      [] ->
        []

      order_bys ->
        for %{expr: expr} = order_by <- order_bys do
          %{
            order_by
            | expr:
                Enum.map(expr, fn
                  {:desc, ast} -> {:asc, ast}
                  {:desc_nulls_first, ast} -> {:asc_nulls_last, ast}
                  {:desc_nulls_last, ast} -> {:asc_nulls_first, ast}
                  {:asc, ast} -> {:desc, ast}
                  {:asc_nulls_last, ast} -> {:desc_nulls_first, ast}
                  {:asc_nulls_first, ast} -> {:desc_nulls_last, ast}
                end)
          }
        end
    end)
  end
end
