# Regression: AugAssign on an Attribute whose receiver is a depth-1
# Subscript on a Name — `edges[i].cap -= flow` — was rejected with
# "AugAssign target shape `Attribute` is not supported (use a Name
# or Subscript target)". Common in network-flow / adjacency-list
# code, where edge records sit in a list and a hot loop mutates
# their fields. Fix has two parts:
#
#   1. New AugAssign clause for `Attribute(Subscript(Name, slice))`
#      in `Pylixir.Converter`: lowers to a rebind of the coll where
#      the i-th element's attr is `Map.put`'d.
#   2. The bare-Attribute *read* path now accepts a Subscript
#      receiver (`xs[i].attr`) when a class is in scope, so the
#      read side of the loop (`min(flow, edges[i].cap)`,
#      `print(edges[0].cap)`) lowers cleanly too.
#
# Pylixir's data class lowering stays immutable (`edges` is rebound,
# not the i-th element), so this preserves Python semantics for the
# single-owner case the failing dataset samples exercise. Depth-2
# subscript chains (`adj[i][j].attr += v`) and chains rooted at
# `self.<attr>` are still rejected — those require modelling
# mutation-through-reference, which is the next milestone.


class Edge:
    def __init__(self, cap):
        self.cap = cap


edges = [Edge(10), Edge(20), Edge(5)]

# Read through subscript.
print(edges[0].cap)  # 10
print(edges[1].cap)  # 20

# AugAssign on the Subscript-rooted Attribute.
edges[0].cap -= 3
edges[1].cap += 5
edges[2].cap *= 2

print(edges[0].cap)  # 7
print(edges[1].cap)  # 25
print(edges[2].cap)  # 10
