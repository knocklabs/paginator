defmodule Paginator.Ecto.Query.NonNull do
  @moduledoc "Builds cursor predicates for fields guaranteed to contain no null values."
  @behaviour Paginator.Ecto.Query.DynamicFilterBuilder

  import Ecto.Query
  import Paginator.Ecto.Query.FieldOrExpression

  @doc "Builds a comparison without nullable branches."
  @spec build_dynamic_filter(map()) :: Ecto.Query.DynamicExpr.t()
  @impl true
  def build_dynamic_filter(%{value: nil}) do
    raise Paginator.Config.ArgumentError, message: "non-null cursor fields cannot have nil values"
  end

  def build_dynamic_filter(args) do
    comparison = comparison(args)

    case args.next_filters do
      true -> comparison
      filters -> dynamic(^comparison or (^field_or_expr_equal(args) and ^filters))
    end
  end

  defp comparison(%{sort_order: order, direction: direction} = args)
       when (order in [:asc, :asc_nulls_first, :asc_nulls_last] and direction == :after) or
              (order in [:desc, :desc_nulls_first, :desc_nulls_last] and direction == :before) do
    field_or_expr_greater(args)
  end

  defp comparison(%{sort_order: order, direction: direction} = args)
       when (order in [:asc, :asc_nulls_first, :asc_nulls_last] and direction == :before) or
              (order in [:desc, :desc_nulls_first, :desc_nulls_last] and direction == :after) do
    field_or_expr_less(args)
  end
end
