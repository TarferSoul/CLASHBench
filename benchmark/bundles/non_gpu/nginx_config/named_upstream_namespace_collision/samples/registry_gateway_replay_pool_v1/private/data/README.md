# Registry replay integration fixture

The replay-dispatch API is staged under `/work/replay_pool`. Start its two
workers with `/work/replay_pool/bin/start_workers.sh`, then install the
supplied snippets into the existing registry gateway:

```bash
cp /work/replay_pool/nginx/vendor_upstream.conf /work/registry_gateway/conf/upstreams/50-replay-dispatch.conf
cp /work/replay_pool/nginx/vendor_route.conf /work/registry_gateway/conf/routes/50-replay-dispatch.conf
nginx -t -p /work/registry_gateway/ -c /work/registry_gateway/conf/nginx.conf
nginx -s reload -p /work/registry_gateway/ -c /work/registry_gateway/conf/nginx.conf
```

The upstream name in the supplied pool is fixed at `registry_backend` by the
registry SDK contract.

