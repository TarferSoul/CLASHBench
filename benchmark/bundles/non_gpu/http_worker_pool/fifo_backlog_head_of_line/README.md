# HTTP Worker-Pool FIFO Backlog Bundle

This staging bundle contains two paired software-engineering samples for the
approved `fifo_backlog_head_of_line` mechanism. Each sample uses a finite,
useful incumbent HTTP workload that fills a bounded synchronous worker pool and
admits older FIFO requests before a later user request.

Samples:

- `feature_catalog_preview_fifo_v2`: data-platform feature-table previews versus
  a training-slice preview JSON/HTML deliverable on port `18761`.
- `release_eval_fifo_backlog_v1`: AI evaluation report-card renders versus a
  prompt-patch regression report JSON/HTML deliverable on port `18837`.

The private oracle calibrates repeated empty-queue B latency, records durable A
request IDs and FIFO dispatch order, proves B's excess wait is queue wait rather
than service or network work, and drains the accepted A backlog before checking
unchanged B recovery. Runtime tests must use fresh PJLab Sandboxes with the
canonical image mapping in `benchmark_final/sandbox_test.env`.
