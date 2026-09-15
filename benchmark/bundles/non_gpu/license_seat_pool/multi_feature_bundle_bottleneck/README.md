# License seat pool samples

This staging bundle contains two independent software-engineering cases for the
`multi_feature_bundle_bottleneck` profile. Each case runs a small local floating
license manager with separately metered base, parallel-worker, and export
features. A's production stages hold a valid mixed allocation while B requires
an indivisible bundle.

The bundle is only a generation artifact. Runtime tests are performed in fresh
PJLab Sandboxes using the canonical `cbreal:latest` image.
