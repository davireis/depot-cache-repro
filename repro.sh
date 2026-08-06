#!/bin/bash
# Min-repro: registry cache-from import behavior when the cache manifest is
# present but a referenced layer blob has been deleted ("evicted").
#
# Correct behavior: cache probe matches, blob fetch 404s -> degrade to a cache
# MISS and rebuild (exit 0). Bug: hard failure ("failed to load ref" /
# "not found" / "failed to solve").
#
# Arms:
#   ./repro.sh control        # vanilla buildkit (docker-container driver)
#   ./repro.sh depot          # depot builders (needs $REPRO_REG reachable from
#                             # the internet, e.g. a cloudflared tunnel)
#   ./repro.sh down           # cleanup
set -euo pipefail
cd "$(dirname "$0")"

NET=repro-net
REG_NAME=repro-reg
REG_PORT=5000
BUILDER=repro-ctl
# Registry host as seen FROM the builder. Control arm: container DNS name.
REG_FOR_BUILDER="${REPRO_REG:-$REG_NAME:$REG_PORT}"
CACHE_REF="$REG_FOR_BUILDER/repro:cache"

log() { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }

up() {
  docker network inspect $NET >/dev/null 2>&1 || docker network create $NET
  if ! docker ps --format '{{.Names}}' | grep -q "^$REG_NAME$"; then
    docker rm -f $REG_NAME 2>/dev/null || true
    # Host port 5001: macOS AirPlay squats 5000. In-network the registry is
    # always $REG_NAME:5000; the host publish exists only for the tunnel.
    docker run -d --name $REG_NAME --network $NET -p "${REG_HOST_PORT:-5001}:5000" \
      -e REGISTRY_STORAGE_DELETE_ENABLED=true registry:2
    sleep 2
  fi
}

make_builder() {
  docker buildx rm $BUILDER 2>/dev/null || true
  docker buildx create --name $BUILDER --driver docker-container \
    --driver-opt network=$NET --buildkitd-config buildkitd.toml >/dev/null
}

populate() {
  log "populate: build + cache-to $CACHE_REF"
  date > a.txt   # fresh content each invocation -> fresh layer digests
  docker buildx build --builder "$1" \
    --cache-to "type=registry,ref=$CACHE_REF,mode=min,image-manifest=true,oci-mediatypes=true" \
    --output type=cacheonly . 2>&1 | tail -3
}

REG_LOCAL="localhost:${REG_HOST_PORT:-5001}"

layer_digests() {
  curl -sf -H 'Accept: application/vnd.oci.image.manifest.v1+json' \
    "http://$REG_LOCAL/v2/repro/manifests/cache" \
  | python3 -c 'import json,sys; [print(l["digest"]) for l in json.load(sys.stdin)["layers"]]'
}

evict() {
  log "evict: DELETE layer blobs via registry API (clean 404s, manifest keeps its tag)"
  # rm-ing the data file simulates corruption (200 + empty body -> short read),
  # not eviction. The DELETE API unlinks the blob so GET/HEAD 404 — the state a
  # quota GC leaves behind.
  layer_digests | while read -r d; do
    code=$(curl -s -o /dev/null -w '%{http_code}' -X DELETE "http://$REG_LOCAL/v2/repro/blobs/$d")
    echo "DELETE $d -> $code"
  done
}

verify_state() {
  log "verify: manifest still served, layer blobs gone"
  layer_digests | while read -r d; do
    code=$(curl -s -o /dev/null -w '%{http_code}' -I "http://$REG_LOCAL/v2/repro/blobs/$d")
    echo "blob HEAD $d -> $code (expect 404)"
  done
}

runfrom() {
  log "run: cold builder, cache-from only -> expect graceful MISS + rebuild"
  set +e
  docker buildx build --builder "$1" --progress plain \
    --cache-from "type=registry,ref=$CACHE_REF" \
    --output type=docker,name=repro:out . >run.log 2>&1
  rc=$?
  set -e
  tail -12 run.log
  echo
  if [ $rc -eq 0 ]; then
    if grep -q 'CACHED' run.log; then
      echo "VERDICT: exit 0 WITH cache hits despite missing blob — inspect run.log (lazy ref never materialized?)"
    else
      echo "VERDICT: PASS — degraded to cache miss and rebuilt (correct behavior)"
    fi
  else
    echo "VERDICT: BUG REPRODUCED — hard failure instead of cache miss (exit $rc)"
    grep -iE 'failed to load ref|not found|failed to solve|blob' run.log | head -5
  fi
  return 0
}

control() {
  up
  make_builder
  populate $BUILDER
  make_builder            # cold local state: fresh buildkitd, cache only in registry
  evict
  verify_state
  runfrom $BUILDER
}

depot_arm() {
  [ -n "${REPRO_REG:-}" ] || { echo "set REPRO_REG=<public-host:port> (cloudflared tunnel to localhost:$REG_PORT)"; exit 2; }
  up
  log "depot populate"
  date > a.txt
  depot build --project "${DEPOT_PROJECT:?set DEPOT_PROJECT}" \
    --cache-to "type=registry,ref=$CACHE_REF,mode=min,image-manifest=true,oci-mediatypes=true" \
    --output type=cacheonly . 2>&1 | tail -3
  evict
  verify_state
  log "depot run: cache-from only"
  set +e
  depot build --project "${DEPOT_PROJECT:?set DEPOT_PROJECT}" --progress plain \
    --cache-from "type=registry,ref=$CACHE_REF" \
    --output type=cacheonly . >run.log 2>&1
  rc=$?
  set -e
  tail -12 run.log
  [ $rc -eq 0 ] && echo "VERDICT: depot degraded gracefully" \
                || { echo "VERDICT: DEPOT BUG REPRODUCED (exit $rc)"; grep -iE 'failed to load ref|not found|failed to solve|blob' run.log | head -5; }
}

# Builder-native tier: metadata survives, snapshot content deleted — the state
# a builder-disk GC/restore leaves when it prunes content without updating
# buildkit's databases. No registry involved at all.
native() {
  up
  make_builder
  local VOL=buildx_buildkit_${BUILDER}0_state
  local CTR=buildx_buildkit_${BUILDER}0
  log "native: warm the local cache (build twice, second must be fully CACHED)"
  date > a.txt
  docker buildx build --builder $BUILDER --output type=cacheonly . >/dev/null 2>&1
  docker buildx build --builder $BUILDER --progress plain --output type=cacheonly . 2>&1 | grep -c CACHED

  log "native: stop buildkitd, delete snapshot content (keep every .db), restart"
  docker stop $CTR >/dev/null
  docker run --rm -v $VOL:/s busybox sh -c \
    'rm -rf /s/runc-overlayfs/snapshots/snapshots/* && echo "snapshot dirs deleted"; ls /s/runc-overlayfs/snapshots'
  docker start $CTR >/dev/null; sleep 2

  log "native run A: identical build (wants full cache hit)"
  set +e
  docker buildx build --builder $BUILDER --progress plain --output type=docker,name=repro:native . >native_a.log 2>&1
  ra=$?
  set -e
  tail -6 native_a.log; echo "exit=$ra"

  log "native run B: append a step (forces mounting cached parent snapshot)"
  printf 'FROM busybox:1.37\nCOPY a.txt /a.txt\nRUN cat /a.txt > /b && head -c 1048576 /dev/urandom > /pad && sleep 1\nRUN cat /b /a.txt > /c\nRUN echo extra >> /c\n' > Dockerfile.native
  set +e
  docker buildx build --builder $BUILDER --progress plain -f Dockerfile.native --output type=docker,name=repro:native2 . >native_b.log 2>&1
  rb=$?
  set -e
  tail -6 native_b.log; echo "exit=$rb"

  echo
  for r in "A:$ra:native_a.log" "B:$rb:native_b.log"; do
    IFS=: read -r n rc f <<EOF
$r
EOF
    if [ "$rc" -eq 0 ]; then echo "VERDICT $n: graceful (rebuilt or served)"; else
      echo "VERDICT $n: HARD FAILURE (exit $rc):"; grep -iE 'failed to load ref|not found|failed to solve|snapshot' "$f" | head -3
    fi
  done
}

down() {
  docker buildx rm $BUILDER 2>/dev/null || true
  docker rm -f $REG_NAME 2>/dev/null || true
  docker network rm $NET 2>/dev/null || true
}

case "${1:-control}" in
  control) control ;;
  native) native ;;
  depot) depot_arm ;;
  down) down ;;
  *) echo "usage: $0 {control|native|depot|down}"; exit 2 ;;
esac
