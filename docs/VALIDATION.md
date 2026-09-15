# Validation record

Validation performed during preparation on 2026-09-15:

| Check | Result |
|---|---|
| Python unit tests: validity, resource limits, paths, judge schema | Passed (10 tests) |
| Docker smoke image from public `python:3.12-slim` | Built successfully |
| End-to-end deterministic smoke | Passed; incumbent preserved, complete trace, no model metrics emitted |
| Real system-resource case oracle: `cluster_access_reconciler_vs_recovery_preflight_v1` | Passed in Docker using the locally exported frozen bundle |
| Full public CPU image and three native CLI installations | Local build blocked on Debian package download; GitHub Actions build check configured |
| Real provider-backed native-harness evaluation | Not run in this preparation check |
| Full 268-case suite | Not run; public data package pending |
| GPU runtime | Not validated; case-specific image/assets required |

These checks establish the portable controller path, not paper-result
reproduction. The real-case data used for the local oracle check is excluded
from this Git repository. CI reruns unit tests and the no-API Docker smoke.
