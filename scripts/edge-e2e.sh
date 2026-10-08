#!/bin/sh
set -eu

# End-to-end proof of the real idfon-edge ingress against a real resource
# provider (idfond `provider.start`), not the fake H3 router the crate tests
# use. Covers the paths the device pass never exercised:
#
#   - ticket requester auth (header, cookie, ?ticket=), forwarded over H3 and
#     authorized by the provider as an owner-issued bearer ticket (P3)
#   - path_scope: a scoped ticket reads its prefix and is refused outside it
#   - the `<ref>.localhost` virtual-host form (the wildcard URL shape)
#   - option A: the edge as a known QUIC peer (token auth + resource.read grant)
#   - P2: a daemon with IDFON_EDGE_URL + `idfon fetch --prefer edge`
#   - TLS termination with a self-signed cert
#   - auth-gated /metrics counters
#   - idfon.edge.access request logging (under the default log filter)
#
# PASS requires every HTTP status/body to match.

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

# The daemon core is reached through the vendored dylib, so build it first (the
# thin idfond links it); flags must match native/build.zig.
RUSTFLAGS="-C link-arg=-Wl,-install_name,@executable_path/libiroh_c_ffi.dylib" \
  cargo build --release --manifest-path native/vendor/iroh-c-ffi/Cargo.toml
cargo build --release -p idfond -p idfon-cli -p idfon-edge

# A relink can leave an ad-hoc signature that no longer matches the pages; the
# kernel then SIGKILLs the process at exec ("Code Signature Invalid").
codesign --force -s - target/release/libiroh_c_ffi.dylib target/release/idfond

NUF="$root/target/release/idfon"
DAEMON="$root/target/release/idfond"
EDGE="$root/target/release/idfon-edge"

W=$(mktemp -d /tmp/idfon-edge-e2e.XXXXXX)
pids=""
cleanup() {
  if [ -n "$pids" ]; then kill $pids 2>/dev/null || true; fi
  rm -rf "$W"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# Polls a log for a line, then echoes the address the edge printed.
edge_addr() { # log
  for _ in $(seq 1 100); do
    if grep -q "listening on" "$1" 2>/dev/null; then
      sed -n 's/.*listening on [a-z]*:\/\/\([^ ]*\).*/\1/p' "$1" | head -1
      return 0
    fi
    sleep 0.1
  done
  echo "FAIL: edge did not start; log:" >&2
  cat "$1" >&2
  exit 1
}

# curl wrapper: body to $W/body, status to stdout.
get() { curl -sS -o "$W/body" -w '%{http_code}' "$@"; }
assert_code() { # expected url [curl args...]
  expected=$1; shift
  got=$(get "$@")
  [ "$got" = "$expected" ] || fail "expected HTTP $expected, got $got for: $*"
}
assert_body() { # expected body url [curl args...]
  expected=$1; shift
  get "$@" >/dev/null
  [ "$(cat "$W/body")" = "$expected" ] || fail "expected body '$expected', got '$(cat "$W/body")'"
}

# --- owner: a real daemon serving a shared root over H3 ----------------------
mkdir -p "$W/owner/data" "$W/owner/root/public" "$W/owner/root/private"
echo hello-public > "$W/owner/root/public/hello.txt"
echo top-secret > "$W/owner/root/private/secret.txt"
echo root-level > "$W/owner/root/top.txt"

A="$W/owner/idfond.sock"
"$DAEMON" --socket "$A" --data-dir "$W/owner/data" >"$W/owner.log" 2>&1 &
pids="$pids $!"
for _ in $(seq 1 100); do "$NUF" --socket "$A" status --json >/dev/null 2>&1 && break; sleep 0.1; done
"$NUF" --socket "$A" status --json >/dev/null 2>&1 || fail "owner daemon not ready"
"$NUF" --socket "$A" provider start --root "$W/owner/root" >/dev/null

OWNER_EP=$("$NUF" --socket "$A" status --json | jq -r .result.identity.endpoint_id)
EXP=$(( $(date +%s) + 3600 ))
SCOPED=$("$NUF" --socket "$A" access ticket --subject requester \
  --capability resource.read --expires-at "$EXP" --path-scope /fs/public)
UNSCOPED=$("$NUF" --socket "$A" access ticket --subject requester \
  --capability resource.read --expires-at "$EXP")
[ "$(echo "$SCOPED" | jq -r .path_scope)" = "/fs/public" ] || fail "scoped ticket has no path_scope"
echo "PASS: owner daemon + scoped/unscoped resource.read tickets issued"

# --- edge 1: ticket requester auth (the transparent P3 ingress) --------------
"$EDGE" --bind 127.0.0.1:0 --require-ticket resource.read \
  --key-file "$W/edge-ticket.key" --allow "$OWNER_EP" >"$W/edge-ticket.log" 2>&1 &
pids="$pids $!"
E1=$(edge_addr "$W/edge-ticket.log")
U1="http://$E1/$OWNER_EP"

assert_code 401 "$U1/fs/public/hello.txt"
assert_body hello-public "$U1/fs/public/hello.txt" -H "x-idfon-ticket: $SCOPED"
echo "PASS: ticket header admits the request"

# A WKWebView carries the ticket in a cookie or query, not a header.
assert_body hello-public "$U1/fs/public/hello.txt" -H "Cookie: idfon_ticket=$SCOPED"
assert_body hello-public -G --data-urlencode "ticket=$SCOPED" "$U1/fs/public/hello.txt"
echo "PASS: cookie and ?ticket= admit the request"

# path_scope is enforced by the provider, and the refusal is a 403 (not 502).
assert_code 403 "$U1/fs/private/secret.txt" -H "x-idfon-ticket: $SCOPED"
assert_body top-secret "$U1/fs/private/secret.txt" -H "x-idfon-ticket: $UNSCOPED"
assert_body root-level "$U1/fs/top.txt" -H "x-idfon-ticket: $UNSCOPED"
echo "PASS: path_scope refuses outside the prefix; an unscoped ticket reads it"

# RFC 3339 expiry is accepted alongside epoch seconds.
RFC_EXP=$(python3 -c 'import datetime;print((datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%SZ"))')
RFC=$("$NUF" --socket "$A" access ticket --subject requester \
  --capability resource.read --expires-at "$RFC_EXP" --path-scope /fs/public)
assert_body hello-public "$U1/fs/public/hello.txt" -H "x-idfon-ticket: $RFC"
echo "PASS: RFC 3339 ticket expiry"

# Virtual-host form: the ref is the host, so the URL path is just the resource.
assert_body hello-public "http://$E1/fs/public/hello.txt" \
  -H "Host: $OWNER_EP.localhost" -H "x-idfon-ticket: $SCOPED"
echo "PASS: <ref>.localhost virtual host"

# Health bypasses requester auth; an unlisted ref is not resolved.
assert_body ok "http://$E1/healthz"
assert_code 404 "http://$E1/nope/fs/public/hello.txt" -H "x-idfon-ticket: $SCOPED"

# Metrics are gated by requester auth and report the observed requests.
assert_code 401 "http://$E1/metrics"
assert_code 200 "http://$E1/metrics" -H "x-idfon-ticket: $SCOPED"
grep -q "idfon_edge_requests_total" "$W/body" || fail "metrics body has no counters"
echo "PASS: /metrics (auth-gated) reports edge counters"

# Per-request logging uses the custom idfon.edge.access target.
grep -q "idfon.edge.access" "$W/edge-ticket.log" || fail "no idfon.edge.access request log"
echo "PASS: request logging (idfon.edge.access)"

# --- edge 2: option A, the edge as a known QUIC peer -------------------------
"$EDGE" --bind 127.0.0.1:0 --token s3cret \
  --key-file "$W/edge-token.key" --allow "$OWNER_EP" >"$W/edge-token.log" 2>&1 &
pids="$pids $!"
E2=$(edge_addr "$W/edge-token.log")
EDGE_EP=$(sed -n 's/^idfon-edge \([0-9a-f]*\) .*/\1/p' "$W/edge-token.log" | head -1)
[ -n "$EDGE_EP" ] || fail "could not read the token edge's endpoint id"
"$NUF" --socket "$A" peer add "$EDGE_EP" --name idfon-edge --endpoint-id "$EDGE_EP" >/dev/null
"$NUF" --socket "$A" access allow --subject "$EDGE_EP" --capability resource.read >/dev/null

assert_code 401 "http://$E2/$OWNER_EP/fs/public/hello.txt"
assert_body top-secret "http://$E2/$OWNER_EP/fs/private/secret.txt" \
  -H "Authorization: Bearer s3cret"
echo "PASS: edge-as-known-peer (token auth + resource.read grant)"

# --- P2: a daemon fetching through the edge (EdgeBackend) --------------------
B="$W/requester/idfond.sock"
mkdir -p "$W/requester/data"
IDFON_EDGE_URL="http://$E2" IDFON_EDGE_TOKEN=s3cret \
  "$DAEMON" --socket "$B" --data-dir "$W/requester/data" >"$W/requester.log" 2>&1 &
pids="$pids $!"
for _ in $(seq 1 100); do "$NUF" --socket "$B" status --json >/dev/null 2>&1 && break; sleep 0.1; done
fetched=$("$NUF" --socket "$B" fetch --prefer edge "idfon://$OWNER_EP/fs/public/hello.txt")
[ "$fetched" = "hello-public" ] || fail "fetch --prefer edge returned '$fetched'"
echo "PASS: idfon fetch --prefer edge (P2 EdgeBackend)"

# --- edge 3: TLS termination (self-signed) ----------------------------------
if command -v openssl >/dev/null 2>&1; then
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$W/tls.key" -out "$W/tls.crt" \
    -days 1 -subj "/CN=*.localhost" >/dev/null 2>&1
  "$EDGE" --bind 127.0.0.1:0 --require-ticket resource.read \
    --tls-cert "$W/tls.crt" --tls-key "$W/tls.key" \
    --key-file "$W/edge-tls.key" --allow "$OWNER_EP" >"$W/edge-tls.log" 2>&1 &
  pids="$pids $!"
  E3=$(edge_addr "$W/edge-tls.log")
  assert_body hello-public "https://$E3/$OWNER_EP/fs/public/hello.txt" \
    -k -H "x-idfon-ticket: $SCOPED"
  echo "PASS: TLS termination"
else
  echo "SKIP: TLS case (openssl not found)"
fi

echo "PASS: idfon-edge end-to-end against a real provider"
