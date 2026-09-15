# Retained heap high-water-mark samples

This staged bundle contains two paired A+B samples for the approved
`memory_capacity/retained_heap_high_watermark` profile.

- `code_index_service_vs_symbol_vectors_v1` uses a 4 GiB cgroup. A warms and
  retains a repository symbol index; B builds validated partitioned symbol
  vectors and summaries.
- `feature_cache_api_vs_int8_quant_v1` uses a 6 GiB cgroup. A warms and retains
  decoded feature partitions; B creates and verifies a CPU int8 model bundle.

Both construction oracles require B-alone success, a useful and stable A
high-water mark, memory-specific B failure with warmed A, unchanged original A
identity and canary correctness, and equivalent B recovery after normal A
release.

The evaluated runtime exposes only `/work`, the selected task, ordinary process
and cgroup observations, and the task's normal inputs. Source, private controls,
trust state, grades, and evidence stay root-only.
