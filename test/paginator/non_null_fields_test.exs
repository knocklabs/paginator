defmodule Paginator.NonNullFieldsTest do
  use Paginator.DataCase

  alias Paginator.{Config, Cursor}
  alias Paginator.Ecto.Query, as: PaginationQuery

  test "non-null fields use strict comparisons in both directions for every sort order" do
    for order <- [
          :asc,
          :asc_nulls_first,
          :asc_nulls_last,
          :desc,
          :desc_nulls_first,
          :desc_nulls_last
        ],
        direction <- [:before, :after] do
      opts = [cursor_fields: [id: order], non_null_fields: [:id]]
      opts = Keyword.put(opts, direction, Cursor.encode(%{id: 42}))

      {sql, _} =
        from(c in Customer, order_by: [{^order, c.id}])
        |> PaginationQuery.paginate(opts)
        |> query_sql()

      comparison =
        if (order in [:asc, :asc_nulls_first, :asc_nulls_last] and direction == :after) or
             (order in [:desc, :desc_nulls_first, :desc_nulls_last] and direction == :before),
           do: ">",
           else: "<"

      assert sql =~ "c0.\"id\" #{comparison} $1"
      refute sql =~ "IS NULL"
    end
  end

  test "preserves pages, encoded cursors and counts with existing and legacy cursors" do
    customers = insert_list(5, :customer) |> Enum.sort_by(& &1.id, &>=/2)
    [newest, _, middle, _, oldest] = customers
    query = from(c in Customer, order_by: [desc: c.id])
    defaults = [cursor_fields: [id: :desc], limit: 2, include_total_count: true]

    for bounds <- [
          [],
          [before: Cursor.encode(%{id: oldest.id})],
          [after: Cursor.encode(%{id: newest.id})],
          [before: Cursor.encode(%{id: oldest.id}), after: Cursor.encode(%{id: newest.id})],
          [before: Cursor.encode(%{id: newest.id})],
          [after: Cursor.encode(%{id: oldest.id})],
          [before: legacy_cursor(middle.id)],
          [after: legacy_cursor(middle.id)]
        ] do
      opts = defaults ++ bounds
      expected = Repo.paginate(query, opts)
      actual = Repo.paginate(query, opts ++ [non_null_fields: [:id]])
      assert actual == expected
      assert actual.metadata.total_count == 5
    end
  end

  test "preserves nullable fields and composite cursor tie breaking" do
    insert(:customer, name: nil)
    first = insert(:customer, name: "same")
    insert(:customer, name: "same")
    insert(:customer, name: "other")
    query = from(c in Customer, order_by: [desc: c.name, asc: c.id])

    for direction <- [:before, :after] do
      opts = [cursor_fields: [name: :desc, id: :asc], include_total_count: true]
      opts = Keyword.put(opts, direction, Cursor.encode(%{name: first.name, id: first.id}))
      assert Repo.paginate(query, opts ++ [non_null_fields: [:id]]) == Repo.paginate(query, opts)
    end

    opts = [
      cursor_fields: [name: :desc, id: :asc],
      before: Cursor.encode(%{name: "same", id: first.id})
    ]

    {sql, _} =
      query |> PaginationQuery.paginate(opts ++ [non_null_fields: [:id]]) |> query_sql()

    assert sql =~ "\"name\" IS NULL"
    refute sql =~ "\"id\" IS NULL"
  end

  test "supports non-null named bindings" do
    query = from(c in Customer, as: :customer, order_by: [desc: c.id])

    opts = [
      cursor_fields: [{{:customer, :id}, :desc}],
      non_null_fields: [{:customer, :id}],
      before: Cursor.encode(%{{:customer, :id} => 42})
    ]

    {sql, _} = query |> PaginationQuery.paginate(opts) |> query_sql()
    assert sql =~ "c0.\"id\" > $1"
    refute sql =~ "IS NULL"
  end

  test "non-null leading fields retain equal-value tie breaking" do
    first = insert(:customer, name: "same")
    second = insert(:customer, name: "same")
    last = insert(:customer, name: "other")
    query = from(c in Customer, order_by: [desc: c.name, asc: c.id])
    opts = [cursor_fields: [name: :desc, id: :asc], non_null_fields: [:name, :id]]

    page = Repo.paginate(query, opts ++ [after: Cursor.encode(%{name: first.name, id: first.id})])
    assert Enum.map(page.entries, & &1.id) == [second.id, last.id]

    page =
      Repo.paginate(query, opts ++ [before: Cursor.encode(%{name: second.name, id: second.id})])

    assert Enum.map(page.entries, & &1.id) == [first.id]
  end

  test "nullable cursor behavior remains the default" do
    query = from(c in Customer, order_by: [desc: c.id])
    opts = [cursor_fields: [id: :desc], before: Cursor.encode(%{id: 42})]
    {sql, _} = query |> PaginationQuery.paginate(opts) |> query_sql()
    assert sql =~ "\"id\" IS NULL"
  end

  test "rejects nil cursor values for non-null fields" do
    opts = [cursor_fields: [id: :desc], non_null_fields: [:id], before: Cursor.encode(%{id: nil})]

    assert_raise Config.ArgumentError, "non-null cursor fields cannot have nil values", fn ->
      Customer |> order_by(desc: :id) |> PaginationQuery.paginate(opts)
    end
  end

  test "rejects unknown non-null fields" do
    config = Config.new(cursor_fields: [id: :desc], non_null_fields: [:name])

    assert_raise Config.ArgumentError, fn -> Config.validate!(config) end
  end

  test "opts expression fields in by name with explicit and implicit sort orders" do
    handler = fn -> dynamic([c], fragment("COALESCE(length(?), 0)", c.name)) end
    query = from(c in Customer, order_by: [desc: fragment("COALESCE(length(?), 0)", c.name)])

    for fields <- [[{{:rank_value, handler}, :desc}], [rank_value: handler]],
        direction <- [:before, :after],
        cursor <- [Cursor.encode(%{rank_value: 4}), legacy_cursor(4)] do
      opts = [cursor_fields: fields, sort_direction: :desc, non_null_fields: [:rank_value]]
      opts = Keyword.put(opts, direction, cursor)
      Config.validate!(Config.new(opts))

      {sql, params} = query |> PaginationQuery.paginate(opts) |> query_sql()
      comparison = if direction == :before, do: ">", else: "<"

      assert sql =~ "COALESCE(length(c0.\"name\"), 0) #{comparison} $1"
      assert hd(params) == 4
      refute sql =~ "IS NULL"
    end
  end

  test "preserves expression pages and tie breaking when opted in by name" do
    insert(:customer, name: "longer")
    first = insert(:customer, name: "same")
    insert(:customer, name: "same")
    insert(:customer, name: nil)

    query =
      from(c in Customer,
        select_merge: %{rank_value: fragment("COALESCE(length(?), 0)", c.name)},
        order_by: [desc: fragment("COALESCE(length(?), 0)", c.name), asc: c.id]
      )

    opts = [
      cursor_fields: [
        {{:rank_value, fn -> dynamic([c], fragment("COALESCE(length(?), 0)", c.name)) end},
         :desc},
        {:id, :asc}
      ],
      include_total_count: true,
      limit: 2
    ]

    for direction <- [:before, :after] do
      bounds = [{direction, Cursor.encode(%{rank_value: 4, id: first.id})}]
      strict_opts = opts ++ bounds ++ [non_null_fields: [:rank_value, :id]]
      expected = Repo.paginate(query, opts ++ bounds)
      assert Repo.paginate(query, strict_opts) == expected
      assert expected.entries != []

      {sql, _} = query |> PaginationQuery.paginate(strict_opts) |> query_sql()
      refute sql =~ "IS NULL"
    end
  end

  defp query_sql(query), do: Repo.to_sql(:all, query)

  defp legacy_cursor(value) do
    [value] |> :erlang.term_to_binary() |> Base.url_encode64()
  end
end
