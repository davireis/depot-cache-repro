# [Draft] moby/buildkit issue

**Title**: Registry cache-from: matched cache whose blobs are gone (evicted/GC'd) hard-fails the build instead of degrading to a cache miss

## Description

When `--cache-from type=registry` imports a cache manifest that matches, the
matched steps become lazy remote refs. If a referenced layer blob no longer
exists in the registry (quota eviction, GC race, registry cleanup), the build
hard-fails at materialization instead of treating the chain as a cache miss and
re-executing the steps:

```
ERROR: failed to build: failed to solve: failed to copy: httpReadSeeker:
failed open: could not fetch content descriptor sha256:4ec52d…
(application/vnd.oci.image.layer.v1.tar+gzip) from remote: not found
```

The corruption variant (blob exists but truncated) fails similarly
(`short read: expected 126 bytes but got 0: unexpected EOF`).

The build inputs are fully sufficient to re-execute every step — the cache is
an optimization, so a broken cache entry should behave as a miss (possibly with
a warning), never as a build failure.

This appears to be the deterministic core behind a long tail of
"unreproducible" reports: #2332, #2631, #4449, #2568, #1388. They were hard to
pin because nobody controlled the evictor; the repro below does.

## Deterministic reproduction

```bash
# 1. registry + builder
docker network create repro-net
docker run -d --name repro-reg --network repro-net -p 5001:5000 \
  -e REGISTRY_STORAGE_DELETE_ENABLED=true registry:2
cat > buildkitd.toml <<'EOF'
[registry."repro-reg:5000"]
  http = true
EOF
docker buildx create --name repro --driver docker-container \
  --driver-opt network=repro-net --buildkitd-config buildkitd.toml

# 2. trivial build, populate cache
cat > Dockerfile <<'EOF'
FROM busybox:1.37
COPY a.txt /a.txt
RUN cat /a.txt > /b && head -c 1048576 /dev/urandom > /pad && sleep 1
RUN cat /b /a.txt > /c
EOF
date > a.txt
docker buildx build --builder repro \
  --cache-to type=registry,ref=repro-reg:5000/repro:cache,mode=min,image-manifest=true,oci-mediatypes=true \
  --output type=cacheonly .

# 3. "evict": DELETE every layer blob the cache manifest references
#    (manifest stays tagged — the state quota-based GCs leave behind)
curl -s -H 'Accept: application/vnd.oci.image.manifest.v1+json' \
  localhost:5001/v2/repro/manifests/cache \
  | jq -r '.layers[].digest' \
  | xargs -I{} curl -s -X DELETE localhost:5001/v2/repro/blobs/{}

# 4. cold builder, cache-from only, output that materializes layers
docker buildx rm repro && docker buildx create --name repro --driver docker-container \
  --driver-opt network=repro-net --buildkitd-config buildkitd.toml
docker buildx build --builder repro \
  --cache-from type=registry,ref=repro-reg:5000/repro:cache \
  --output type=docker,name=repro:out .
# -> hard failure (expected: cache miss + rebuild, exit 0)
```

Note: `--output type=cacheonly` in step 4 exits 0 with all steps CACHED — the
lazy refs are never materialized, so the broken state is also undetectable by a
"pre-flight" build.

## Versions

buildx v0.30.1, builder `moby/buildkit:buildx-stable-1`, engine 29.1.3.

## Same gap in the local state tiers

The equivalent inconsistency in buildkitd's own state directory — snapshot
content deleted while `cache.db`/`containerdmeta.db`/`metadata_v2.db` survive
(a crash mid-GC, a partial disk restore, an out-of-band cleanup) — also
hard-fails instead of degrading:

- context-sync store: `failed to walk: resolve : lstat …snapshots/1: no such
  file or directory` at `[internal] load build context` (the incremental
  session sync trusts a dead snapshot rather than falling back to a full
  re-transfer; sometimes self-heals after N failed builds, sometimes not);
- layer snapshots: `failed to commit <ref> during finalize: lstat
  …snapshots/7/fs: no such file or directory` — permanently sticky until the
  state dir is wiped.

Repro: stop buildkitd (docker-container driver), `rm -rf
/var/lib/buildkit/runc-overlayfs/snapshots/snapshots/*` keeping the `.db`
files, restart, rebuild.

## Expected

Missing/corrupt cache content — remote or local — ⇒ cache miss for the
affected chain (re-execute / re-transfer), ideally with a warning. Never a
build failure: cache is advisory by design, and both registries that evict at
blob granularity under live tags (quota/TTL caches) and long-lived persistent
builders make these states routine.
