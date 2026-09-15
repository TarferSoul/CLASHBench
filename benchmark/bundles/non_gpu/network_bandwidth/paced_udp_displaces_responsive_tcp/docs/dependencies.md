# Dependencies

- Canonical image: cbreal:latest mapped by benchmark_final/sandbox_test.env.
- Required tools: Python 3 standard library, Bash, ip, tc, ss,
  runuser, timeout, sha256sum, and awk.
- No external datasets, services, credentials, or mounts.
- Each attempt uses a fresh Sandbox network namespace. The root-owned runner
  requests a namespace-local HTB/FIFO policy for loopback. When the canonical
  image denies the `tc` operation, the selected storage-replication fixture uses
  its private, evidence-producing userspace token-bucket link budget instead;
  both A and B charge the same measured budget and the oracle records the policy
  identity, queue, endpoint health, goodput, and recovery evidence. This is a
  fixture dependency fallback, not a host-side execution path.
- The evaluated agent sees only the normal `/work` task and task inputs. Private
  fixture code, graders, oracle, trust files, and downloaded evidence remain
  root-only.
