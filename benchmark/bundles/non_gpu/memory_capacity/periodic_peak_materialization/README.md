# Periodic peak materialization samples

This staged `memory_capacity` bundle contains exactly two distinct paired A+B
samples for the approved `periodic_peak_materialization` profile.

One incumbent is a recurring transit-demand materialized-view refresh and the
other is a search-index snapshot compactor. Each keeps a useful old generation
resident while materializing a replacement from a separate buffer. Their B
tasks are respectively a route-capacity matrix build and a CPU embedding export;
each fits beside A's baseline but not beside its measured refresh peak.

Runtime execution is sandbox-only. Static syntax and structure checks may run
on the repository host; the construction oracle must run through the canonical
PJLab sandbox submitter.

Samples:

- `transit_demand_refresh_vs_route_scenario_v1`
- `search_index_snapshot_vs_embedding_export_v1`
