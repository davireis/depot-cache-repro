# The bug: BuildKit treats missing cache content as fatal, not as a miss

## One sentence

A build cache is an optimization — if an entry is gone, the correct behaviour is to
re-execute the step. BuildKit instead **fails the build**, in every tier where cache
metadata can outlive the content it points at.

## Why that distinction matters

Cache misses cost time. Cache *failures* cost a red build, and they are not
self-healing: the same commit fails identically on every retry until someone
re-keys the build definitions or wipes the builder's state. On CI this is
indistinguishable from a real breakage, so it burns human attention, not just
minutes.

The trigger state — metadata alive, content gone — is not exotic. It is the normal
result of:

- a registry-side quota or TTL GC that evicts blobs while leaving the cache tag in place;
- a crash or interruption partway through a GC;
- a partial restore of a builder's state volume;
- an out-of-band cleanup of a snapshot directory;
- an interrupted cache export that leaves a manifest referencing blobs that never
  finished uploading.

Any long-lived builder or quota-bounded cache registry will produce it eventually.

## Three signatures, all hard failures

### 1. Registry `--cache-from`, blobs evicted

Cache manifest matches, steps are marked `CACHED` as lazy remote refs, then export
fails materializing them:

```
ERROR: failed to build: failed to solve: failed to copy: httpReadSeeker:
failed open: could not fetch content descriptor sha256:4ec52d…
(application/vnd.oci.image.layer.v1.tar+gzip) from remote: not found
```

The corruption variant — blob present but truncated — fails as
`short read: expected 126 bytes but got 0: unexpected EOF`.

Worth noting: `--output type=cacheonly` exits **0** with everything `CACHED`, because
the lazy refs are never materialized. A "pre-flight" build cannot detect the broken
state; only a real output does.

### 2. Builder-local context-sync store

Snapshot content deleted, `.db` metadata intact. At `[internal] load build context`:

```
failed to walk: resolve : lstat …snapshots/1: no such file or directory
```

The incremental session sync trusts a dead snapshot instead of falling back to a full
re-transfer. Sometimes self-heals after N failed attempts (the failed resolve drops the
ref), sometimes not — recovery is nondeterministic.

### 3. Builder-local layer snapshot store

```
failed to commit <ref> during finalize: lstat …snapshots/7/fs:
no such file or directory
```

**Permanently sticky** — identical failure on every retry until the state volume is
wiped or the build definitions are re-keyed so new chain IDs route around the dead
records.

## Expected

Missing or corrupt cache content, remote or local, should mark the affected chain as a
**miss** and re-execute or re-transfer, ideally with a warning. The build inputs are by
definition sufficient to rebuild — that is what makes it a cache.

## Reproducing

All three are deterministic and scripted here; see [README.md](README.md) for the
protocol and [DRAFT-buildkit-issue.md](DRAFT-buildkit-issue.md) for a self-contained
copy-pasteable version.

```
./repro.sh control   # registry tier: local registry:2, evict blobs via the DELETE API
./repro.sh native    # builder-local tiers: drop snapshot dirs, keep the .db files
./repro.sh depot     # optional parity check on a hosted builder
```

Reproduced on vanilla buildx v0.30.1 with builder image
`moby/buildkit:buildx-stable-1`, engine 29.1.3. **This is upstream BuildKit
behaviour, not specific to any hosted build provider** — providers only make the
trigger state common.

## Two things providers can do independently

1. **Don't evict at blob granularity under a live cache tag.** If a quota GC reclaims
   blobs, the manifests referencing them should go too; a tag that resolves to
   unfetchable content is worse than no tag.
2. **Reject manifests referencing blobs that were never fully uploaded.** `registry:2`
   already does this (`MANIFEST_BLOB_UNKNOWN`, HTTP 400); `put_conformance.sh` in this
   repo probes for it. Accepting them means a single interrupted export poisons that
   cache tag for every later consumer.

## Prior reports this likely explains

A long tail of "unreproducible" issues: moby/buildkit #2332, #2631, #4449, #2568,
#1388. They were hard to pin down because nobody controlled the evictor. Here the
eviction step is explicit, so the failure is deterministic.
