defmodule Paginator.Ecto.Query.DynamicFilterBuilder do
  @dispatch_table %{
    desc: Paginator.Ecto.Query.DescNullsFirst,
    desc_nulls_first: Paginator.Ecto.Query.DescNullsFirst,
    desc_nulls_last: Paginator.Ecto.Query.DescNullsLast,
    asc: Paginator.Ecto.Query.AscNullsLast,
    asc_nulls_last: Paginator.Ecto.Query.AscNullsLast,
    asc_nulls_first: Paginator.Ecto.Query.AscNullsFirst
  }

  @callback build_dynamic_filter(%{
              direction: :after | :before,
              entity_position: integer(),
              column: term(),
              value: term(),
              next_filters: Ecto.Query.dynamic() | boolean()
            }) :: term()

  @type sort_order ::
          :asc
          | :asc_nulls_first
          | :asc_nulls_last
          | :desc
          | :desc_nulls_first
          | :desc_nulls_last

  @type direction :: :after | :before

  @spec build!(%{
          sort_order: sort_order(),
          direction: direction(),
          entity_position: integer(),
          column: term(),
          value: term(),
          next_filters: Ecto.Query.dynamic() | boolean()
        }) :: term()
  def build!(input) do
    case Map.fetch(@dispatch_table, input.sort_order) do
      {:ok, module} ->
        if Map.get(input, :non_null, false) do
          Paginator.Ecto.Query.NonNull.build_dynamic_filter(input)
        else
          apply(module, :build_dynamic_filter, [input])
        end

      :error ->
        available_sort_orders = Map.keys(@dispatch_table) |> Enum.join(", ")

        raise(
          "Invalid sorting value #{inspect(input.sort_order)}, please use either #{available_sort_orders}"
        )
    end
  end
end
