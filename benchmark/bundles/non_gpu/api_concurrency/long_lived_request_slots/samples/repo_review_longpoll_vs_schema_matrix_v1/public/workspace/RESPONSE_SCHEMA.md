# Pinned review response contract

POST JSON to the configured endpoint with `tenant`, `deployment`, `repository`,
`source_digest`, `token_count`, and `interval_ms=90`. Include headers
`X-Client-Owner` and `X-Request-ID`.

HTTP 200 is newline-delimited JSON. Six `analysis_delta` objects have increasing
`token_index` values. The final `analysis_complete` object contains a `response`
with exactly the requested `request_id`, `repository`, `source_digest`, and
deployment, plus nonempty `risk`, `findings`, and `compatibility` fields. HTTP
429 returns an error code of `concurrency_limit`.
