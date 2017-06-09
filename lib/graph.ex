defmodule Graph do
  @moduledoc """
  This module defines a directed graph data structure, which supports both acyclic and cyclic forms.
  It also defines the API for creating, manipulating, and querying that structure.

  This is intended as a replacement for `:digraph`, which requires the use of 3 ETS tables at a minimum,
  but up to 6 at a time during certain operations (such as `get_short_path/3`). In environments where many
  graphs are in memory at a time, this can be dangerous, as it is easy to hit the system limit for max ETS tables,
  which will bring your node down. This graph implementation does not use ETS, so it can be used freely without
  concern for hitting this limit.

  As far as memory usage is concerned, `Graph` should be fairly compact in memory, but if you want to do a rough
  comparison between the memory usage for a graph between `libgraph` and `digraph`, use `:digraph.info/1` and
  `Graph.info/1` on the two graphs, and both contain memory usage information. Keep in mind we don't have a precise
  way to measure the memory usage of a term in memory, whereas ETS is able to give a precise answer, but we do have
  a fairly good way to estimate the usage of a term, and we use that method within `libgraph`.

  The Graph struct is composed of a map of vertex ids to vertices, a map of vertex ids to their out neighbors,
  a map of vertex ids to their in neighbors (both in and out neighbors are represented as MapSets), a map of
  vertex ids to vertex labels (which are only stored if a non-nil label was provided), and a map of edge ids
  (which are a tuple of the source vertex id to destination vertex id) to a map of edge metadata (label/weight).

  The reason we use several different maps to represent the graph, particularly the inverse index of in/out neighbors,
  is that it allows us to perform very efficient queries on the graph without having to store vertices multiple times,
  it is also more efficient to use maps with small keys, particularly integers or binaries. The use of several maps does
  mean we use more space in memory, but because the bulk of those maps are just integers, it's about as compact as we can
  make it while still remaining performant.

  There are benchmarks provided with this library which compare it directly to `:digraph` for some common operations,
  and thus far, `libgraph` is equal to or outperforms `:digraph` in all of them.

  The only bit of data I have not yet evaluated is how much garbage is generated when querying/manipulating the graph
  between `libgraph` and `digraph`, but I suspect the use of ETS means that `digraph` is able to keep that to a minimum.
  Until I verify if that's the case, I would assume that `libgraph` has higher memory requirements, but better performance,
  and is able to side-step the ETS limit. If your requirements, like mine, mean that you are dynamically constructing and querying
  graphs concurrently, I think `libgraph` is the better choice - however if you either need the APIs of `:digraph` that I have
  not yet implemented, or do not have the same use case, I would stick to `:digraph` for now.
  """
  defstruct in_edges: %{},
            out_edges: %{},
            edges_meta: %{},
            vertex_labels: %{},
            vertices: %{}

  alias Graph.Edge

  @type vertex_id :: non_neg_integer
  @type vertex :: term
  @type t :: %__MODULE__{
    in_edges: %{vertex_id => MapSet.t},
    out_edges: %{vertex_id => MapSet.t},
    edges_meta: %{{vertex_id, vertex_id} => map},
    vertex_labels: %{vertex_id => term},
    vertices: %{vertex_id => vertex}
  }

  @doc """
  Creates a new graph.
  """
  @spec new() :: t
  def new do
    %__MODULE__{}
  end

  @doc """
  Returns a map of summary information about this graph.

  NOTE: The `size_in_bytes` value is an estimate, not a perfectly precise value, but
  should be close enough to be useful.

  ## Example

      iex> g = Graph.new |> Graph.add_vertices([:a, :b, :c, :d])
      ...> g = g |> Graph.add_edges([{:a, :b}, {:b, :c}])
      ...> Graph.info(g)
      %{num_vertices: 4, num_edges: 2, size_in_bytes: 952}
  """
  @spec info(t) :: %{num_edges: non_neg_integer, num_vertices: non_neg_integer}
  def info(%__MODULE__{} = g) do
    %{num_edges: num_edges(g),
      num_vertices: num_vertices(g),
      size_in_bytes: Graph.Utils.sizeof(g)}
  end

  @doc """
  Converts the given Graph to DOT format, which can then be converted to
  a number of other formats via Graphviz, e.g. `dot -Tpng out.dot > out.png`.

  If labels are set on a vertex, then those labels are used in the DOT output
  in place of the vertex itself. If no labels were set, then the vertex is
  stringified if it's a primitive type and inspected if it's not, in which
  case the inspect output will be quoted and used as the vertex label in the DOT file.

  Edge labels and weights will be shown as attributes on the edge definitions, otherwise
  they use the same labelling scheme for the involved vertices as described above.

  NOTE: Currently this function assumes graphs are directed graphs, but in the future
  it will support undirected graphs as well.

  ## Example

      > g = Graph.new |> Graph.add_vertices([:a, :b, :c, :d])
      > g = Graph.add_edges([{:a, :b}, {:b, :c}, {:b, :d}, {:c, :d}])
      > g = Graph.label_vertex(g, :a, :start)
      > g = Graph.label_vertex(g, :d, :finish)
      > g = Graph.update_edge(g, :b, :d, weight: 3)
      > IO.puts(Graph.to_dot(g))
      strict digraph {
          start
          b
          c
          finish
          start -> b
          b -> c
          b -> finish [weight=3]
          c -> finish
      }
  """
  @spec to_dot(t) :: {:ok, binary} | {:error, term}
  def to_dot(%__MODULE__{} = g) do
    Graph.Serializers.DOT.serialize(g)
  end

  @doc """
  Returns the number of edges in the graph

  ## Example

      iex> g = Graph.add_edges(Graph.new, [{:a, :b}, {:b, :c}, {:a, :a}])
      ...> Graph.num_edges(g)
      3
  """
  @spec num_edges(t) :: non_neg_integer
  def num_edges(%__MODULE__{out_edges: es}) do
    Enum.reduce(es, 0, fn {_, out}, sum -> sum + MapSet.size(out) end)
  end

  @doc """
  Returns the number of vertices in the graph

  ## Example

      iex> g = Graph.add_vertices(Graph.new, [:a, :b, :c])
      ...> Graph.num_vertices(g)
      3
  """
  @spec num_vertices(t) :: non_neg_integer
  def num_vertices(%__MODULE__{vertices: vs}) do
    map_size(vs)
  end

  @doc """
  Returns true if and only if the graph `g` is a tree.
  """
  @spec is_tree?(t) :: boolean
  def is_tree?(%__MODULE__{out_edges: es, vertices: vs} = g) do
    num_edges = Enum.reduce(es, 0, fn {_, out}, sum -> sum + MapSet.size(out) end)
    num_vertices = map_size(vs)
    if num_edges == (num_vertices - 1) do
      length(components(g)) == 1
    else
      false
    end
  end

  @doc """
  Returns true if the graph is an aborescence, a directed acyclic graph,
  where the *root*, a vertex, of the arborescence has a unique path from itself
  to every other vertex in the graph.
  """
  @spec is_arborescence?(t) :: boolean
  defdelegate is_arborescence?(g), to: Graph.Directed

  @doc """
  Returns the root vertex of the arborescence, if one exists, otherwise nil.
  """
  @spec arborescence_root(t) :: vertex | nil
  defdelegate arborescence_root(g), to: Graph.Directed

  @doc """
  Returns true if and only if the graph `g` is acyclic.
  """
  @spec is_acyclic?(t) :: boolean
  defdelegate is_acyclic?(g), to: Graph.Directed

  @doc """
  Returns true if the graph `g` is not acyclic.
  """
  @spec is_cyclic?(t) :: boolean
  def is_cyclic?(%__MODULE__{} = g) do
    not is_acyclic?(g)
  end

  @doc """
  Returns true if graph `g1` is a subgraph of `g2`.

  A graph is a subgraph of another graph if it's vertices and edges
  are a subset of that graph's vertices and edges.

  ## Example

      iex> g1 = Graph.new |> Graph.add_vertices([:a, :b, :c, :d]) |> Graph.add_edge(:a, :b) |> Graph.add_edge(:b, :c)
      ...> g2 = Graph.new |> Graph.add_vertices([:b, :c]) |> Graph.add_edge(:b, :c)
      ...> Graph.is_subgraph?(g2, g1)
      true
  """
  @spec is_subgraph?(t, t) :: boolean
  def is_subgraph?(%__MODULE__{out_edges: es1, vertices: vs1}, %__MODULE__{out_edges: es2, vertices: vs2}) do
    for {v, _} <- vs1 do
      unless Map.has_key?(vs2, v), do: throw(:not_subgraph)
    end
    for {g1_v_id, g1_v_out} <- es1 do
      g2_v_out = Map.get(es2, g1_v_id, MapSet.new)
      unless MapSet.subset?(g1_v_out, g2_v_out) do
        throw :not_subgraph
      end
    end
    true
  catch
    :throw, :not_subgraph ->
      false
  end

  @doc """
  See `dijkstra/1`.
  """
  @spec get_shortest_path(t, vertex, vertex) :: [vertex]
  defdelegate get_shortest_path(g, a, b), to: Graph.Pathfinding, as: :dijkstra

  @doc """
  Gets the shortest path between `a` and `b`.

  As indicated by the name, this uses Dijkstra's algorithm for locating the shortest path, which
  means that edge weights are taken into account when determining which vertices to search next. By
  default, all edges have a weight of 1, so vertices are inspected at random; which causes this algorithm
  to perform a naive depth-first search of the graph until a path is found. If your edges are weighted however,
  this will allow the algorithm to more intelligently navigate the graph.

  ## Example

      iex> g = Graph.new |> Graph.add_edges([{:a, :b}, {:b, :c}, {:c, :d}, {:b, :d}])
      ...> Graph.dijkstra(g, :a, :d)
      [:a, :b, :d]

      iex> g = Graph.new |> Graph.add_vertices([:a, :b, :c, :d])
      ...> g = Graph.add_edges(g, [{:a, :c}, {:b, :c}, {:b, :d}])
      ...> Graph.dijkstra(g, :a, :d)
      nil
  """
  @spec dijkstra(t, vertex, vertex) :: [vertex]
  defdelegate dijkstra(g, a, b), to: Graph.Pathfinding

  @doc """
  Gets the shortest path between `a` and `b`.

  The A* algorithm is very much like Dijkstra's algorithm, except in addition to edge weights, A*
  also considers a heuristic function for determining the lower bound of the cost to go from vertex
  `v` to `b`. The lower bound *must* be less than the cost of the shortest path from `v` to `b`, otherwise
  it will do more harm than good. Dijkstra's algorithm can be reframed as A* where `lower_bound(v)` is always 0.

  This function puts the heuristics in your hands, so you must provide the heuristic function, which should take
  a single parameter, `v`, which is the vertex being currently examined. Your heuristic should then determine what the
  lower bound for the cost to reach `b` from `v` is, and return that value.

  ## Example

      iex> g = Graph.new |> Graph.add_edges([{:a, :b}, {:b, :c}, {:c, :d}, {:b, :d}])
      ...> Graph.a_star(g, :a, :d, fn _ -> 0 end)
      [:a, :b, :d]

      iex> g = Graph.new |> Graph.add_vertices([:a, :b, :c, :d])
      ...> g = Graph.add_edges(g, [{:a, :c}, {:b, :c}, {:b, :d}])
      ...> Graph.a_star(g, :a, :d, fn _ -> 0 end)
      nil
  """
  @spec a_star(t, vertex, vertex, (vertex, vertex -> integer)) :: [vertex]
  defdelegate a_star(g, a, b, hfun), to: Graph.Pathfinding

  @doc """
  Builds a list of paths between vertex `a` and vertex `b`.

  The algorithm used here is a depth-first search, which evaluates the whole
  graph until all paths are found. Order is guaranteed to be deterministic,
  but not guaranteed to be in any meaningful order (i.e. shortest to longest).

  ## Example
      iex> g = Graph.new |> Graph.add_edges([{:a, :b}, {:b, :c}, {:c, :d}, {:b, :d}, {:c, :a}])
      ...> Graph.get_paths(g, :a, :d)
      [[:a, :b, :c, :d], [:a, :b, :d]]

      iex> g = Graph.new |> Graph.add_vertices([:a, :b, :c, :d])
      ...> g = Graph.add_edges(g, [{:a, :c}, {:b, :c}, {:b, :d}])
      ...> Graph.get_paths(g, :a, :d)
      []
  """
  @spec get_paths(t, vertex, vertex) :: [[vertex]]
  defdelegate get_paths(g, a, b), to: Graph.Pathfinding, as: :all

  @doc """
  Return a list of all the edges, where each edge is expressed as a tuple
  of `{A, B}`, where the elements are the vertices involved, and implying the
  direction of the edge to be from `A` to `B`.

  NOTE: You should be careful when using this on dense graphs, as it produces
  lists with whatever you've provided as vertices, with likely many copies of
  each. I'm not sure if those copies are shared in-memory as they are unchanged,
  so it *should* be fairly compact in memory, but I have not verified that to be sure.

  ## Example

      iex> g = Graph.new |> Graph.add_vertex(:a) |> Graph.add_vertex(:b) |> Graph.add_vertex(:c)
      ...> g = g |> Graph.add_edge(:a, :c) |> Graph.add_edge(:b, :c)
      ...> Graph.edges(g)
      [%Graph.Edge{v1: :a, v2: :c}, %Graph.Edge{v1: :b, v2: :c}]

  """
  @spec edges(t) :: [Edge.t]
  def edges(%__MODULE__{out_edges: edges, edges_meta: edges_meta, vertices: vs}) do
    edges
    |> Enum.flat_map(fn {source_id, out_neighbors} ->
      source = Map.get(vs, source_id)
      for out_neighbor <- out_neighbors do
        meta = Map.get(edges_meta, {source_id, out_neighbor})
        Edge.new(source, Map.get(vs, out_neighbor), meta)
      end
    end)
  end

  @doc """
  Returns a list of all the vertices in the graph.

  NOTE: You should be careful when using this on large graphs, as the list it produces
  contains every vertex on the graph. I have not yet verified whether Erlang ensures that
  they are a shared reference with the original, or copies, but if the latter it could result
  in running out of memory if the graph is too large.

  ## Example

      iex> g = Graph.new |> Graph.add_vertex(:a) |> Graph.add_vertex(:b)
      ...> Graph.vertices(g)
      [:a, :b]
  """
  @spec vertices(t) :: vertex
  def vertices(%__MODULE__{vertices: vs}) do
    Map.values(vs)
  end

  @doc """
  Returns the label for the given vertex.
  If no label was assigned, it returns nil.

  ## Example

      iex> g = Graph.new |> Graph.add_vertex(:a) |> Graph.label_vertex(:a, :my_label)
      ...> Graph.vertex_label(g, :a)
      :my_label
  """
  @spec vertex_label(t, vertex) :: term | nil
  def vertex_label(%__MODULE__{vertex_labels: labels}, v) do
    with v1_id <- Graph.Utils.vertex_id(v),
         true <- Map.has_key?(labels, v1_id) do
      Map.get(labels, v1_id)
    else
      _ -> nil
    end
  end

  @doc """
  Returns the label for the given vertex.
  If no label was assigned, it returns nil.

  ## Example

      iex> g = Graph.new |> Graph.add_edge(:a, :b, label: :my_edge)
      ...> Graph.edge_label(g, :a, :b)
      :my_edge
  """
  @spec edge_label(t, vertex, vertex) :: term | nil
  def edge_label(%__MODULE__{edges_meta: meta}, v1, v2) do
    with v1_id <- Graph.Utils.vertex_id(v1),
         v2_id <- Graph.Utils.vertex_id(v2),
         %{label: label} <- Map.get(meta, {v1_id, v2_id}) do
      label
    else
      _ -> nil
    end
  end

  @doc """
  Adds a new vertex to the graph. If the vertex is already present in the graph, the add is a no-op.

  You can provide an optional label for the vertex, aside from the variety of uses this has for working
  with graphs, labels will also be used when exporting a graph in DOT format.

  ## Example

      iex> g = Graph.new |> Graph.add_vertex(:a, :mylabel) |> Graph.add_vertex(:a)
      ...> [:a] = Graph.vertices(g)
      ...> Graph.vertex_label(g, :a)
      :mylabel
  """
  @spec add_vertex(t, vertex) :: t
  def add_vertex(%__MODULE__{vertices: vs, vertex_labels: vl} = g, v, label \\ nil) do
    id = Graph.Utils.vertex_id(v)
    case Map.get(vs, id) do
      nil when is_nil(label) ->
        %__MODULE__{g | vertices: Map.put(vs, id, v)}
      nil ->
        %__MODULE__{g | vertices: Map.put(vs, id, v), vertex_labels: Map.put(vl, id, label)}
      _ ->
        g
    end
  end

  @doc """
  Like `add_vertex/2`, but takes a list of vertices to add to the graph.

  ## Example

      iex> g = Graph.new |> Graph.add_vertices([:a, :b, :a])
      ...> Graph.vertices(g)
      [:a, :b]
  """
  @spec add_vertices(t, [vertex]) :: t
  def add_vertices(%__MODULE__{} = g, vs) when is_list(vs) do
    Enum.reduce(vs, g, &add_vertex(&2, &1))
  end

  @doc """
  Updates the label for the given vertex.

  If no such vertex exists in the graph, `{:error, {:invalid_vertex, v}}` is returned.

  ## Example

      iex> g = Graph.new |> Graph.add_vertex(:a, :foo)
      ...> :foo = Graph.vertex_label(g, :a)
      ...> g = Graph.label_vertex(g, :a, :bar)
      ...> Graph.vertex_label(g, :a)
      :bar
  """
  @spec label_vertex(t, vertex, term) :: t | {:error, {:invalid_vertex, vertex}}
  def label_vertex(%__MODULE__{vertices: vs, vertex_labels: labels} = g, v, label) do
    with v_id <- Graph.Utils.vertex_id(v),
         true <- Map.has_key?(vs, v_id),
         labels <- Map.put(labels, v_id, label) do
      %__MODULE__{g | vertex_labels: labels}
    else
      _ -> {:error, {:invalid_vertex, v}}
    end
  end

  @doc """
  Replaces `vertex` with `new_vertex` in the graph.

  ## Example

      iex> g = Graph.new |> Graph.add_vertices([:a, :b]) |> Graph.add_edge(:a, :b)
      ...> [:a, :b] = Graph.vertices(g)
      ...> g = Graph.replace_vertex(g, :a, :c)
      ...> [:b, :c] = Graph.vertices(g)
      ...> Graph.edges(g)
      [%Graph.Edge{v1: :c, v2: :b}]
  """
  @spec replace_vertex(t, vertex, vertex) :: t | {:error, :no_such_vertex}
  def replace_vertex(%__MODULE__{vertices: vs, vertex_labels: labels, out_edges: oe, in_edges: ie, edges_meta: em} = g, v, rv) do
    with   v_id <- Graph.Utils.vertex_id(v),
           true <- Map.has_key?(vs, v_id),
           rv_id <- Graph.Utils.vertex_id(rv),
           vs <- Map.put(Map.delete(vs, v_id), rv_id, rv) do
      oe =
        for {from_id, to} = e <- oe, into: %{} do
          fid = if from_id == v_id, do: rv_id, else: from_id
          cond do
            MapSet.member?(to, v_id) ->
              {fid, MapSet.put(MapSet.delete(to, v_id), rv_id)}
            from_id != fid ->
              {fid, to}
            :else ->
              e
          end
        end
      ie =
        for {to_id, from} = e <- ie, into: %{} do
          tid = if to_id == v_id, do: rv_id, else: to_id
          cond do
            MapSet.member?(from, v_id) ->
              {tid, MapSet.put(MapSet.delete(from, v_id), rv_id)}
            to_id != tid ->
              {tid, from}
            :else ->
              e
          end
        end
      meta =
        em
        |> Stream.map(fn
          {{^v_id, ^v_id}, meta} -> {{rv_id, rv_id}, meta}
          {{^v_id, v2_id}, meta} -> {{rv_id, v2_id}, meta}
          {{v1_id, ^v_id}, meta} -> {{v1_id, rv_id}, meta}
          edge -> edge
        end)
        |> Enum.into(%{})
      labels =
        case Map.get(labels, v_id) do
          nil -> labels
          label -> Map.put(Map.delete(labels, v_id), rv_id, label)
        end
      %__MODULE__{g | vertices: vs, out_edges: oe, in_edges: ie, edges_meta: meta, vertex_labels: labels}
    else
      _ -> {:error, :no_such_vertex}
    end
  end

  @doc """
  Removes a vertex from the graph, as well as any edges which refer to that vertex. If the vertex does
  not exist in the graph, it is a no-op.

  ## Example

      iex> g = Graph.new |> Graph.add_vertex(:a) |> Graph.add_vertex(:b) |> Graph.add_edge(:a, :b)
      ...> [:a, :b] = Graph.vertices(g)
      ...> [%Graph.Edge{v1: :a, v2: :b}] = Graph.edges(g)
      ...> g = Graph.delete_vertex(g, :b)
      ...> [:a] = Graph.vertices(g)
      ...> Graph.edges(g)
      []
  """
  @spec delete_vertex(t, vertex) :: t
  def delete_vertex(%__MODULE__{out_edges: oe, in_edges: ie, edges_meta: em, vertices: vs} = g, v) do
    with v_id <- Graph.Utils.vertex_id(v),
         true <- Map.has_key?(vs, v_id),
         oe <- Map.delete(oe, v_id),
         ie <- Map.delete(ie, v_id),
         vs <- Map.delete(vs, v_id) do
      oe = for {id, ns} <- oe, do: {id, MapSet.delete(ns, v_id)}, into: %{}
      em = for {{id1, id2}, _} = e <- em, v_id != id1 && v_id != id2, do: e, into: %{}
      %__MODULE__{g |
                  vertices: vs,
                  out_edges: oe,
                  in_edges: ie,
                  edges_meta: em}
    else
      _ -> g
    end
  end

  @doc """
  Like `delete_vertex/2`, but takes a list of vertices to delete from the graph.

  ## Example

      iex> g = Graph.new |> Graph.add_vertices([:a, :b, :c]) |> Graph.delete_vertices([:a, :b])
      ...> Graph.vertices(g)
      [:c]
  """
  @spec delete_vertices(t, [vertex]) :: t
  def delete_vertices(%__MODULE__{} = g, vs) when is_list(vs) do
    Enum.reduce(vs, g, &delete_vertex(&2, &1))
  end

  @doc """
  Like `add_edge/3` or `add_edge/4`, but takes a `Graph.Edge` struct created with
  `Graph.Edge.new/2` or `Graph.Edge.new/3`.

  ## Example

      iex> g = Graph.new |> Graph.add_edge(Graph.Edge.new(:a, :b))
      ...> [:a, :b] = Graph.vertices(g)
      ...> Graph.edges(g)
      [%Graph.Edge{v1: :a, v2: :b}]
  """
  @spec add_edge(t, Edge.t) :: t
  def add_edge(%__MODULE__{} = g, %Edge{v1: v1, v2: v2} = edge) do
    add_edge(g, v1, v2, Edge.to_meta(edge))
  end

  @doc """
  Adds an edge connecting `a` to `b`. If either `a` or `b` do not exist in the graph,
  they are automatically added. Adding the same edge more than once does not create multiple edges,
  each edge is only ever stored once.

  Edges have a default weight of 1, and an empty (nil) label. You can change this by passing options
  to this function, as shown below.

  ## Example

      iex> g = Graph.new |> Graph.add_edge(:a, :b)
      ...> [:a, :b] = Graph.vertices(g)
      ...> Graph.edges(g)
      [%Graph.Edge{v1: :a, v2: :b, label: nil, weight: 1}]

      iex> g = Graph.new |> Graph.add_edge(:a, :b, label: :foo, weight: 2)
      ...> [:a, :b] = Graph.vertices(g)
      ...> Graph.edges(g)
      [%Graph.Edge{v1: :a, v2: :b, label: :foo, weight: 2}]
  """
  @spec add_edge(t, vertex, vertex) :: t
  @spec add_edge(t, vertex, vertex, Edge.edge_opts) :: t | {:error, {:invalid_edge_option, term}}
  def add_edge(%__MODULE__{} = g, a, b, opts \\ []) do
    %__MODULE__{in_edges: ie, out_edges: oe, edges_meta: es_meta} = g =
      g |> add_vertex(a) |> add_vertex(b)

    a_id = Graph.Utils.vertex_id(a)
    b_id = Graph.Utils.vertex_id(b)
    out_neighbors =
      case Map.get(oe, a_id) do
        nil -> MapSet.new([b_id])
        ms  -> MapSet.put(ms, b_id)
      end
    in_neighbors =
      case Map.get(ie, b_id) do
        nil -> MapSet.new([a_id])
        ms  -> MapSet.put(ms, a_id)
      end
    meta = Edge.options_to_meta(opts)
    %__MODULE__{g |
      in_edges: Map.put(ie, b_id, in_neighbors),
      out_edges: Map.put(oe, a_id, out_neighbors),
      edges_meta: Map.put(es_meta, {a_id, b_id}, meta)
    }
  catch
    _, {:error, {:invalid_edge_option, _}} = err ->
      err
  end

  @doc """
  Like `add_edge/3`, but takes a list of `Graph.Edge` structs, and adds an edge to the graph for each pair.

  See the docs for `Graph.Edge.new/2` or `Graph.Edge.new/3` for more info.

  ## Examples

      iex> alias Graph.Edge
      ...> edges = [Edge.new(:a, :b), Edge.new(:b, :c, weight: 2)]
      ...> g = Graph.new |> Graph.add_vertices([:a, :b, :c]) |> Graph.add_edges(edges)
      ...> Graph.edges(g)
      [%Graph.Edge{v1: :a, v2: :b}, %Graph.Edge{v1: :b, v2: :c, weight: 2}]

      iex> Graph.new |> Graph.add_vertices([:a, :b, :c]) |> Graph.add_edges([:a, :b])
      {:error, {:invalid_edge, :a}}
  """
  @spec add_edges(t, [Edge.t]) :: t | {:error, {:invalid_edge, term}}
  def add_edges(%__MODULE__{} = g, es) when is_list(es) do
    Enum.reduce(es, g, fn
      %Edge{} = edge, acc ->
        add_edge(acc, edge)
      {v1, v2}, acc ->
        add_edge(acc, v1, v2)
      bad_edge, _acc ->
        throw {:error, {:invalid_edge, bad_edge}}
    end)
  catch
    :throw, {:error, {:invalid_edge, _}} = err ->
      err
  end

  @doc """
  Splits the edge between `v1` and `v2` by inserting a new vertex, `v3`, deleting
  the edge between `v1` and `v2`, and inserting an edge from `v1` to `v3` and from
  `v3` to `v2`.

  The two resulting edges from the split will share the same weight and label.

  ## Example

      iex> g = Graph.new |> Graph.add_vertices([:a, :c]) |> Graph.add_edge(:a, :c, weight: 2)
      ...> g = Graph.split_edge(g, :a, :c, :b)
      ...> Graph.edges(g)
      [%Graph.Edge{v1: :a, v2: :b, weight: 2}, %Graph.Edge{v1: :b, v2: :c, weight: 2}]
  """
  @spec split_edge(t, vertex, vertex, vertex) :: t | {:error, :no_such_edge}
  def split_edge(%__MODULE__{in_edges: ie, out_edges: oe, edges_meta: em} = g, v1, v2, v3) do
    with v1_id  <- Graph.Utils.vertex_id(v1),
         v2_id  <- Graph.Utils.vertex_id(v2),
         {:ok, v1_out} <- Graph.Directed.find_out_edges(g, v1_id),
         {:ok, v2_in}  <- Graph.Directed.find_in_edges(g, v2_id),
          true   <- MapSet.member?(v1_out, v2_id),
          meta   <- Map.get(em, {v1_id, v2_id}),
          v1_out <- MapSet.delete(v1_out, v2_id),
          v2_in  <- MapSet.delete(v2_in, v1_id) do
      %__MODULE__{g |
                  in_edges: Map.put(ie, v2_id, v2_in),
                  out_edges: Map.put(oe, v1_id, v1_out)}
      |> add_vertex(v3)
      |> add_edge(v1, v3, meta)
      |> add_edge(v3, v2, meta)
    else
      _ -> {:error, :no_such_edge}
    end
  end

  @doc """
  Updates the metadata (weight/label) for an edge using the provided options.

  ## Example

      iex> g = Graph.new |> Graph.add_edge(:a, :b)
      ...> [%Graph.Edge{v1: :a, v2: :b, label: nil, weight: 1}] = Graph.edges(g)
      ...> %Graph{} = g = Graph.update_edge(g, :a, :b, weight: 2, label: :foo)
      ...> Graph.edges(g)
      [%Graph.Edge{v1: :a, v2: :b, label: :foo, weight: 2}]
  """
  @spec update_edge(t, vertex, vertex, Edge.edge_opts) :: t | {:error, :no_such_edge}
  def update_edge(%__MODULE__{edges_meta: em} = g, v1, v2, opts) when is_list(opts) do
    with v1_id <- Graph.Utils.vertex_id(v1),
         v2_id <- Graph.Utils.vertex_id(v2),
         opts when is_map(opts) <- Edge.options_to_meta(opts) do
      case Map.get(em, {v1_id, v2_id}) do
        nil ->
          %__MODULE__{g | edges_meta: Map.put(em, {v1_id, v2_id}, opts)}
        meta ->
          %__MODULE__{g | edges_meta: Map.put(em, {v1_id, v2_id}, Map.merge(meta, opts))}
      end
    else
      _ -> g
    end
  end

  @doc """
  Removes an edge connecting `a` to `b`. If no such vertex exits, or the edge does not exist,
  it is effectively a no-op.

  ## Example

      iex> g = Graph.new |> Graph.add_edge(:a, :b) |> Graph.delete_edge(:a, :b)
      ...> [:a, :b] = Graph.vertices(g)
      ...> Graph.edges(g)
      []
  """
  def delete_edge(%__MODULE__{in_edges: ie, out_edges: oe, edges_meta: meta} = g, a, b) do
    with a_id <- Graph.Utils.vertex_id(a),
         b_id <- Graph.Utils.vertex_id(b),
         {:ok, a_out} <- Graph.Directed.find_out_edges(g, a_id),
         {:ok, b_in}  <- Graph.Directed.find_in_edges(g, b_id) do
      a_out = MapSet.delete(a_out, b_id)
      b_in  = MapSet.delete(b_in, a_id)
      meta  = Map.delete(meta, {a_id, b_id})
      %__MODULE__{g |
                  in_edges: Map.put(ie, b_id, b_in),
                  out_edges: Map.put(oe, a_id, a_out),
                  edges_meta: meta}
    else
      _ -> g
    end
  end

  @doc """
  Like `delete_edge/3`, but takes a list of vertex pairs, and deletes the corresponding
  edge from the graph, if it exists.

  ## Examples

      iex> g = Graph.new |> Graph.add_vertices([:a, :b, :c]) |> Graph.add_edge(:a, :b)
      ...> g = Graph.delete_edges(g, [{:a, :b}])
      ...> Graph.edges(g)
      []

      iex> g = Graph.new |> Graph.add_vertices([:a, :b, :c]) |> Graph.add_edge(:a, :b)
      ...> Graph.delete_edges(g, [:a])
      {:error, {:invalid_edge, :a}}
  """
  @spec delete_edges(t, [{vertex, vertex}]) :: t | {:error, {:invalid_edge, term}}
  def delete_edges(%__MODULE__{} = g, es) when is_list(es) do
    Enum.reduce(es, g, fn
      {v1, v2}, acc ->
        delete_edge(acc, v1, v2)
      bad_edge, _acc ->
        throw {:error, {:invalid_edge, bad_edge}}
    end)
  catch
    :throw, {:error, {:invalid_edge, _}} = err ->
      err
  end

  @doc """
  The transposition of a graph is another graph with the direction of all the edges reversed.

  ## Example

      iex> g = Graph.new |> Graph.add_vertices([:a, :b, :c]) |> Graph.add_edge(:a, :b) |> Graph.add_edge(:b, :c)
      ...> g |> Graph.transpose |> Graph.edges
      [%Graph.Edge{v1: :b, v2: :a}, %Graph.Edge{v1: :c, v2: :b}]
  """
  @spec transpose(t) :: t
  def transpose(%__MODULE__{in_edges: ie, out_edges: oe, edges_meta: es_meta} = g) do
    es_meta2 =
      es_meta
      |> Enum.reduce(%{}, fn {{v1, v2}, meta}, acc -> Map.put(acc, {v2, v1}, meta) end)
    %__MODULE__{g | in_edges: oe, out_edges: ie, edges_meta: es_meta2}
  end

  @doc """
  Returns a topological ordering of the vertices of graph `g`, if such an ordering exists, otherwise it returns false.
  For each vertex in the returned list, no out-neighbors occur earlier in the list.

  ## Example

      iex> g = Graph.new |> Graph.add_vertices([:a, :b, :c, :d])
      ...> g = Graph.add_edges(g, [{:a, :b}, {:a, :c}, {:b, :c}, {:c, :d}])
      ...> Graph.topsort(g)
      [:a, :b, :c, :d]

      iex> g = Graph.new |> Graph.add_vertices([:a, :b, :c, :d])
      ...> g = Graph.add_edges(g, [{:a, :b}, {:a, :c}, {:b, :c}, {:c, :d}, {:c, :a}])
      ...> Graph.topsort(g)
      false
  """
  @spec topsort(t) :: [vertex]
  defdelegate topsort(g), to: Graph.Directed, as: :topsort

  @doc """
  Returns a list of connected components, where each component is a list of vertices.

  A *connected component* is a maximal subgraph such that there is a path between each pair of vertices,
  considering all edges undirected.

  A *subgraph* is a graph whose vertices and edges are a subset of the vertices and edges of the source graph.

  A *maximal subgraph* is a subgraph with property `P` where all other subgraphs which contain the same vertices
  do not have that same property `P`.

  ## Example

      iex> g = Graph.new |> Graph.add_vertices([:a, :b, :c, :d])
      ...> g = Graph.add_edges(g, [{:a, :b}, {:a, :c}, {:b, :c}, {:c, :d}, {:c, :a}])
      ...> Graph.components(g)
      [[:d, :b, :c, :a]]
  """
  @spec components(t) :: [[vertex]]
  defdelegate components(g), to: Graph.Directed

  @doc """
  Returns a list of strongly connected components, where each component is a list of vertices.

  A *strongly connected component* is a maximal subgraph such that there is a path between each pair of vertices.

  See `components/1` for the definitions of *subgraph* and *maximal subgraph* if you are unfamiliar with the
  terminology.

  ## Example

      iex> g = Graph.new |> Graph.add_vertices([:a, :b, :c, :d])
      ...> g = Graph.add_edges(g, [{:a, :b}, {:a, :c}, {:b, :c}, {:c, :d}, {:c, :a}])
      ...> Graph.strong_components(g)
      [[:d], [:b, :c, :a]]
  """
  @spec strong_components(t) :: [[vertex]]
  defdelegate strong_components(g), to: Graph.Directed

  @doc """
  Returns an unsorted list of vertices from the graph, such that for each vertex in the list (call it `v`),
  there is a path in the graph from some vertex of `vs` to `v`.

  As paths of length zero are allowed, the vertices of `vs` are also included in the returned list.

  ## Example

      iex> g = Graph.new |> Graph.add_vertices([:a, :b, :c, :d])
      ...> g = Graph.add_edges(g, [{:a, :b}, {:a, :c}, {:b, :c}, {:c, :d}])
      ...> Graph.reachable(g, [:a])
      [:d, :c, :b, :a]
  """
  @spec reachable(t, [vertex]) :: [[vertex]]
  defdelegate reachable(g, vs), to: Graph.Directed

  @doc """
  Returns an unsorted list of vertices from the graph, such that for each vertex in the list (call it `v`),
  there is a path in the graph of length one or more from some vertex of `vs` to `v`.

  As a consequence, only those vertices of `vs` that are included in some cycle are returned.

  ## Example

      iex> g = Graph.new |> Graph.add_vertices([:a, :b, :c, :d])
      ...> g = Graph.add_edges(g, [{:a, :b}, {:a, :c}, {:b, :c}, {:c, :d}])
      ...> Graph.reachable_neighbors(g, [:a])
      [:d, :c, :b]
  """
  @spec reachable_neighbors(t, [vertex]) :: [[vertex]]
  defdelegate reachable_neighbors(g, vs), to: Graph.Directed

  @doc """
  Returns an unsorted list of vertices from the graph, such that for each vertex in the list (call it `v`),
  there is a path from `v` to some vertex of `vs`.

  As paths of length zero are allowed, the vertices of `vs` are also included in the returned list.

  ## Example

      iex> g = Graph.new |> Graph.add_vertices([:a, :b, :c, :d])
      ...> g = Graph.add_edges(g, [{:a, :b}, {:a, :c}, {:b, :c}, {:c, :d}])
      ...> Graph.reaching(g, [:d])
      [:b, :a, :c, :d]
  """
  @spec reaching(t, [vertex]) :: [[vertex]]
  defdelegate reaching(g, vs), to: Graph.Directed

  @doc """
  Returns an unsorted list of vertices from the graph, such that for each vertex in the list (call it `v`),
  there is a path of length one or more from `v` to some vertex of `vs`.

  As a consequence, only those vertices of `vs` that are included in some cycle are returned.

  ## Example

     iex> g = Graph.new |> Graph.add_vertices([:a, :b, :c, :d])
     ...> g = Graph.add_edges(g, [{:a, :b}, {:a, :c}, {:b, :c}, {:c, :a}, {:b, :d}])
     ...> Graph.reaching_neighbors(g, [:b])
     [:b, :c, :a]
  """
  @spec reaching_neighbors(t, [vertex]) :: [[vertex]]
  defdelegate reaching_neighbors(g, vs), to: Graph.Directed

  @doc """
  Returns all vertices of graph `g`. The order is given by a depth-first traversal of the graph,
  collecting visited vertices in preorder.

  ## Example

  Our example code constructs a graph which looks like so:

           :a
             \
              :b
             /  \
           :c   :d
           /
         :e

      iex> g = Graph.new |> Graph.add_vertices([:a, :b, :c, :d, :e])
      ...> g = Graph.add_edges(g, [{:a, :b}, {:b, :c}, {:b, :d}, {:c, :e}])
      ...> Graph.preorder(g)
      [:a, :b, :c, :e, :d]
  """
  @spec preorder(t) :: [vertex]
  defdelegate preorder(g), to: Graph.Directed

  @doc """
  Returns all vertices of graph `g`. The order is given by a depth-first traversal of the graph,
  collecting visited vertices in postorder. More precisely, the vertices visited while searching from an
  arbitrarily chosen vertex are collected in postorder, and all those collected vertices are placed before
  the subsequently visited vertices.

  ## Example

  Our example code constructs a graph which looks like so:

          :a
            \
             :b
            /  \
           :c   :d
          /
         :e

      iex> g = Graph.new |> Graph.add_vertices([:a, :b, :c, :d, :e])
      ...> g = Graph.add_edges(g, [{:a, :b}, {:b, :c}, {:b, :d}, {:c, :e}])
      ...> Graph.postorder(g)
      [:e, :c, :d, :b, :a]
  """
  @spec postorder(t) :: [vertex]
  defdelegate postorder(g), to: Graph.Directed

  @doc """
  Returns a list of vertices from graph `g` which are included in a loop, where a loop is a cycle of length 1.

  ## Example

      iex> g = Graph.new |> Graph.add_vertices([:a, :b, :c]) |> Graph.add_edge(:a, :a)
      ...> Graph.loop_vertices(g)
      [:a]
  """
  @spec loop_vertices(t) :: [vertex]
  defdelegate loop_vertices(g), to: Graph.Directed

  @doc """
  Returns the in-degree of vertex `v` of graph `g`.

  The *in-degree* of a vertex is the number of edges directed inbound towards that vertex.

  ## Example

      iex> g = Graph.new |> Graph.add_vertices([:a, :b, :c]) |> Graph.add_edge(:a, :b)
      ...> Graph.in_degree(g, :b)
      1
  """
  def in_degree(%__MODULE__{} = g, v) do
    with v_id <- Graph.Utils.vertex_id(v),
         {:ok, v_in} <- Graph.Directed.find_in_edges(g, v_id) do
      MapSet.size(v_in)
    else
      _ -> 0
    end
  end

  @doc """
  Returns the out-degree of vertex `v` of graph `g`.

  The *out-degree* of a vertex is the number of edges directed outbound from that vertex.

  ## Example

      iex> g = Graph.new |> Graph.add_vertices([:a, :b, :c]) |> Graph.add_edge(:a, :b)
      ...> Graph.out_degree(g, :a)
      1
  """
  @spec out_degree(t, vertex) :: non_neg_integer
  def out_degree(%__MODULE__{} = g, v) do
    with v_id  <- Graph.Utils.vertex_id(v),
         {:ok, v_out} <- Graph.Directed.find_out_edges(g, v_id) do
      MapSet.size(v_out)
    else
      _ -> 0
    end
  end

  @doc """
  Returns a list of vertices which all have edges coming in to the given vertex `v`.
  """
  @spec in_neighbors(t, vertex) :: [vertex]
  def in_neighbors(%Graph{vertices: vs} = g, v) do
    with v_id <- Graph.Utils.vertex_id(v),
         {:ok, v_in} <- Graph.Directed.find_in_edges(g, v_id) do
      Enum.map(v_in, &Map.get(vs, &1))
    else
      _ -> []
    end
  end

  @doc """
  Returns a list of `Graph.Edge` structs representing the in edges to vertex `v`.
  """
  @spec in_edges(t, vertex) :: Edge.t
  def in_edges(%__MODULE__{vertices: vs, edges_meta: em} = g, v) do
    with v_id <- Graph.Utils.vertex_id(v),
         {:ok, v_in} <- Graph.Directed.find_in_edges(g, v_id) do
      Enum.map(v_in, fn id ->
        v2 = Map.get(vs, id)
        meta = Map.get(em, {id, v_id}, [])
        Edge.new(v2, v, meta)
      end)
    else
      _ -> []
    end
  end

  @doc """
  Returns a list of vertices which the given vertex `v` has edges going to.
  """
  @spec out_neighbors(t, vertex) :: [vertex]
  def out_neighbors(%__MODULE__{vertices: vs} = g, v) do
    with v_id <- Graph.Utils.vertex_id(v),
         {:ok, v_out} <- Graph.Directed.find_out_edges(g, v_id) do
      Enum.map(v_out, &Map.get(vs, &1))
    else
      _ -> []
    end
  end

  @doc """
  Returns a list of `Graph.Edge` structs representing the out edges from vertex `v`.
  """
  @spec out_edges(t, vertex) :: Edge.t
  def out_edges(%__MODULE__{vertices: vs, edges_meta: es_meta} = g, v) do
    with v_id <- Graph.Utils.vertex_id(v),
         {:ok, v_out} <- Graph.Directed.find_out_edges(g, v_id) do
      Enum.map(v_out, fn id ->
        v2 = Map.get(vs, id)
        meta = Map.get(es_meta, {v_id, id}, [])
        Edge.new(v, v2, meta)
      end)
    else
      _ -> []
    end
  end

  @doc """
  Builds a maximal subgraph of `g` which includes all of the vertices in `vs` and the edges which connect them.

  See the test suite for example usage.
  """
  @spec subgraph(t, [vertex]) :: t
  def subgraph(%__MODULE__{vertices: vertices, out_edges: oe, edges_meta: es_meta}, vs) do
    allowed =
      vs
      |> Enum.map(&Graph.Utils.vertex_id/1)
      |> Enum.filter(&Map.has_key?(vertices, &1))
      |> MapSet.new

    Enum.reduce(allowed, Graph.new, fn v_id, sg ->
      v = Map.get(vertices, v_id)
      sg = Graph.add_vertex(sg, v)
      oe
      |> Map.get(v_id, MapSet.new)
      |> MapSet.intersection(allowed)
      |> Enum.reduce(sg, fn v2_id, sg ->
        v2 = Map.get(vertices, v2_id)
        meta = Map.get(es_meta, {v_id, v2_id})
        Graph.add_edge(sg, v, v2, meta)
      end)
    end)
  end
end
