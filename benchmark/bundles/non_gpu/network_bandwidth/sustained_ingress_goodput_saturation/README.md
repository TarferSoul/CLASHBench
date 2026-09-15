# Network bandwidth sample staging bundle

This staging bundle contains exactly two paired A+B samples for the approved
`sustained_ingress_goodput_saturation` profile. It remains under the requested
generation staging directory and is not a final bundle.

`package_mirror_vs_ci_toolchain_fetch_v1` pairs a checksum-verifying package
mirror with a bounded CI toolchain download. `model_cache_warmer_vs_eval_snapshot_fetch_v1`
pairs a model-cache warmer with reranker snapshot materialization. Both use
real streamed HTTP payloads through a finite aggregate response budget, while
their fixtures, resource instances, B contracts, and evidence differ.

The actual bandwidth-consuming A worker drops to `agentb`, and the runner
records same-UID `/proc` visibility plus a `kill -0` actionability probe before
starting the evaluated harness.
