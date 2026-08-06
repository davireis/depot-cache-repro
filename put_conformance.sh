#!/bin/bash
# Registry write-path conformance: PUT a manifest whose config/layer blobs were
# never uploaded. OCI distribution spec: the registry MUST reject it
# (MANIFEST_BLOB_UNKNOWN, 400/404). Accepting it (2xx) poisons cache tags for
# every subsequent consumer.
#
# Runs the same probe against a local registry:2 (control) and, when
# DEPOT_TOKEN + DEPOT_PROJECT + DEPOT_REGISTRY are set, a depot registry
# (treatment). Never prints credentials.
set -euo pipefail

BOGUS_CFG=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
BOGUS_LAYER=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
MANIFEST=$(cat <<EOF
{"schemaVersion":2,"mediaType":"application/vnd.oci.image.manifest.v1+json",
 "config":{"mediaType":"application/vnd.oci.image.config.v1+json","digest":"$BOGUS_CFG","size":2},
 "layers":[{"mediaType":"application/vnd.oci.image.layer.v1.tar+gzip","digest":"$BOGUS_LAYER","size":2}]}
EOF
)

probe() { # $1=label $2=base-url $3=repo [$4=auth-header]
  local code
  local -a auth=()
  [ -n "${4:-}" ] && auth=(-H "$4")
  code=$(printf '%s' "$MANIFEST" | curl -s -o /tmp/put_resp.json -w '%{http_code}' \
    -X PUT ${auth[@]+"${auth[@]}"} \
    -H 'Content-Type: application/vnd.oci.image.manifest.v1+json' \
    --data-binary @- "$2/v2/$3/manifests/conformance-bogus-blobs")
  echo "$1: PUT manifest w/ unknown blobs -> HTTP $code $( [ "${code:0:1}" = 2 ] && echo '** ACCEPTED: NON-CONFORMANT **' || echo '(rejected: conformant)')"
  [ "${code:0:1}" = 2 ] || python3 -c 'import json;print("  error:",json.load(open("/tmp/put_resp.json"))["errors"][0]["code"])' 2>/dev/null || true
}

# Control: local registry:2 (started by repro.sh up)
probe "registry:2 (control)" "http://localhost:${REG_HOST_PORT:-5001}" repro

# Treatment: a depot registry. Needs an ORG token (pull-tokens lack registry
# write scope). Bearer dance per the registry's WWW-Authenticate challenge.
#   DEPOT_TOKEN=<org token> DEPOT_PROJECT=<id> DEPOT_REGISTRY=<org>.registry.depot.dev ./put_conformance.sh
if [ -n "${DEPOT_TOKEN:-}" ] && [ -n "${DEPOT_PROJECT:-}" ] && [ -n "${DEPOT_REGISTRY:-}" ]; then
  BT=$(curl -s -u "x-token:$DEPOT_TOKEN" \
    "https://api.depot.dev/auth/registry/token?service=$DEPOT_REGISTRY&scope=repository:$DEPOT_PROJECT:pull,push" \
    | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d.get("token") or d.get("access_token") or "")')
  if [ -n "$BT" ]; then
    probe "depot (treatment)" "https://$DEPOT_REGISTRY" "$DEPOT_PROJECT" "Authorization: Bearer $BT"
  else
    echo "depot: bearer token fetch failed (org token invalid or endpoint changed)"
  fi
else
  echo "depot: set DEPOT_TOKEN, DEPOT_PROJECT and DEPOT_REGISTRY to run the treatment arm"
fi
