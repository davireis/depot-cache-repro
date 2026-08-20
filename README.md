# Registry cache-from vs evicted blobs — minimal repro

> **[BUG.md](BUG.md)** explains the defect and why it matters. This file is the
> protocol and the raw observations.

**Claim under test**: when a registry cache manifest matches but its layer blobs
have been deleted (quota eviction), the build should degrade to a cache MISS and
re-execute. Instead it hard-fails.

**Result: reproduced on VANILLA BuildKit — not depot-specific.** Depot inherits
it; depot's cache-quota GC just makes the trigger state common.

## Protocol

```
./repro.sh control    # local registry:2 + docker-container builder
```

1. Build a 4-step Dockerfile with
   `--cache-to type=registry,mode=min,image-manifest=true,oci-mediatypes=true`.
2. Evict: `DELETE /v2/repro/blobs/<digest>` for every layer the cache manifest
   references (registry started with `REGISTRY_STORAGE_DELETE_ENABLED=true`).
   Verified: manifest GET 200, every layer blob HEAD 404 — exactly the state a
   quota GC leaves.
3. Recreate the builder (cold local state), rebuild with `--cache-from` only and
   a real output (`type=docker`).

## Observed

Cache keys match, steps are marked CACHED as lazy remote refs, then export
hard-fails materializing them:

```
ERROR: failed to build: failed to solve: failed to copy: httpReadSeeker:
failed open: could not fetch content descriptor sha256:4ec52d… 
(application/vnd.oci.image.layer.v1.tar+gzip) from remote: not found
```

No fallback to re-executing the steps. Exit 1.

Note: deleting the blob's `data` file directly (instead of the DELETE API)
simulates *corruption* (200 + empty body) and fails differently
(`short read: expected 126 bytes but got 0`) — also not fail-soft.

## Versions

- buildx v0.30.1-desktop.1, builder image `moby/buildkit:buildx-stable-1`,
  engine 29.1.3 (macOS Docker Desktop)

## Production incident this models

A large-monorepo CI on hosted persistent builders: recurring
`failed to load ref …: not found` and
`failed to calculate checksum of ref <session>::<id>: "<file>": not found`
(files present on the client) after the provider's cache-quota GC ran.
Deterministic across reruns; recovered only by re-keying the build definitions
(new chain IDs route around the dead records) or disabling registry cache.

## Filing targets

- moby/buildkit: cache/state loss — remote or local — must degrade to
  re-execution / re-transfer (all three tiers above), never fail the build.
- Hosted-builder providers whose quota GC evicts blobs under live cache tags,
  or whose registries accept manifests referencing blobs that never finished
  uploading, industrialize the trigger states.

## Builder-native tier (`./repro.sh native`)

Same principle, local tier: stop buildkitd, delete
`runc-overlayfs/snapshots/snapshots/*` while keeping every `.db`
(metadata alive, content gone — the state a builder-disk GC/restore leaves),
restart, rebuild. Three observed signatures, all hard failures:

1. **Context-sync store**: `failed to walk: resolve : lstat …snapshots/1: no
   such file or directory` at `[internal] load build context` — the
   incremental session sync trusts a dead snapshot instead of falling back to
   a full re-transfer. This is the exact shape of the production
   `failed to calculate checksum of ref <session>::<id>: "<file>": not found`
   errors (file exists on the client).
2. Same state sometimes **self-heals after N failed attempts** (failed resolve
   drops the ref) — and sometimes doesn't; recovery is nondeterministic.
3. **Layer snapshot store**: `failed to commit <ref> during finalize: lstat
   …snapshots/7/fs: no such file or directory` — a dead base-image/layer
   snapshot ref; **permanently sticky**, identical failure on every retry
   until the state volume is wiped or the build definitions are re-keyed
   (which is why bumping our cache-scope constant "fixed" CI: new chain IDs
   skip the dead records).

## Depot arm (optional parity check)

`REPRO_REG=<public-host> ./repro.sh depot` — needs the local registry exposed
publicly (e.g. `cloudflared tunnel --url http://localhost:5001`) so depot's
remote builders can reach it.
