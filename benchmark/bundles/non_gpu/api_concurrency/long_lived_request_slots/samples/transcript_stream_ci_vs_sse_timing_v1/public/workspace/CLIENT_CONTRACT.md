# Transcript stream client contract

Send one `GET` per case to the configured endpoint with query parameters
`tenant`, `stream_id`, `events`, and `interval_ms=80`. Include headers
`X-Client-Owner` and `X-Request-ID` from `stream_contract_cases.json`.

A successful response is `text/event-stream`. Each event has an `event: delta`
line and a JSON `data:` line containing `request_id`, `stream_id`, `index`, and
`text`. The last event is `event: complete`. HTTP 429 has a JSON error object
whose code is `concurrency_limit`.
