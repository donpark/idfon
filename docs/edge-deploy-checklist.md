# Edge deploy + E2E teardown checklist

**Status:** current. The runbook behind issue #54: how the local CallKit test
rig is started, how it is torn down so test-config residue does not recur, and
what the production edge on the droplet needs. Read with
`callkit-integration.md` (the E2E legs) and `idfon-edge.md` (the edge itself).

## A. Local test rig (what the CallKit E2E rings through)

The rig is one test edge on the LAN plus test defaults in both apps. Keep it
entirely under `/tmp` + test keys so §B can remove all of it.

```sh
# Test edge — sandbox APNs (only development builds ring through it) and a
# test token; the real APNs key is ~/.idfon/edge.apns.p8 (one-time Apple
# download; treat like a credential).
./target/debug/idfon-edge --bind 0.0.0.0:8090 --token e2etoken \
  --push-apns-key ~/.idfon/edge.apns.p8 \
  --push-apns-key-id <key-id> --push-apns-team <team-id> \
  --push-apns-url https://api.sandbox.push.apple.com \
  --push-state /tmp/edge-push-e2e.json --key-file /tmp/edge-e2e.key \
  > /tmp/edge-e2e.log 2>&1 &

# Mac app → the test edge (Idfon.app reads these on launch).
defaults write com.idfon.mac idfon.edge.url http://<mac-lan-ip>:8090
defaults write com.idfon.mac idfon.edge.ticket e2e

# iPhone → the test edge (launch args, persisted in the app's UserDefaults).
xcrun devicectl device process launch --device <udid> --console \
  com.idfon.ios --args -edgeurl http://<mac-lan-ip>:8090 -edgeticket e2e
```

Test daemons live in scratch profiles under `/tmp/idfon*` (`--data-dir
/tmp/idfon…`), spawned by `scripts/test-e2e.sh` or by hand. The **app daemon is
not test config**: its profile is `Application Support/Idfon/daemon` and it must
survive teardown.

## B. Session teardown (run when the E2E legs are done)

```sh
scripts/e2e-teardown.sh
```

Kills only scratch-profile daemons (`--data-dir /tmp/idfon*`) and removes their
scratch. Then, by hand — these break the live rig, so only when the session is
really over:

```sh
kill <idfon-edge pid>                       # the test edge (pkill -f edge-e2e)
rm -f /tmp/edge-e2e.key /tmp/edge-e2e.log /tmp/edge-push-e2e.json
defaults delete com.idfon.mac idfon.edge.url
defaults delete com.idfon.mac idfon.edge.ticket
```

iPhone: relaunch without `-edgeurl` (its `idfon.edge.url` defaults key stays
set otherwise). Verify residue is gone:

```sh
ps -axo pid,command | grep -e idfond -e idfon-edge | grep -v grep   # only the app daemon remains
defaults read com.idfon.mac | grep -i edge                          # nothing
```

## C. Droplet deploy (production)

`deploy/digitalocean/README.md` covers provisioning (`pnpm deploy:do`). The
push channel needs more than the stock `compose.yaml` provides:

1. **APNs key on the droplet** — copy `edge.apns.p8` to
   `/srv/idfon-edge/edge.apns.p8` (mode 600) and mount it read-only in
   `deploy/digitalocean/compose.yaml` beside `/etc/idfon-edge`.
2. **Push flags** — extend `command:` with
   `--push-apns-key /var/lib/idfon/edge.apns.p8 --push-apns-key-id <id>
   --push-apns-team <team> --push-apns-url https://api.push.apple.com
   --push-state /var/lib/idfon/edge-push.json`.
   The **production** APNs URL is mandatory: the sandbox URL only rings
   development builds, and TestFlight/App Store builds silently die there.
   (The stock compose does not pass `--push-*` yet — until it does this is a
   manual edit on the droplet.)
3. **Apps on production** — mac: `defaults write com.idfon.mac idfon.edge.url
   https://idfon.net` + `idfon.edge.ticket <prod ticket>`; iPhone: relaunch
   with `-edgeurl https://idfon.net -edgeticket <prod ticket>`.
4. **Verify** — `curl https://idfon.net/healthz`, then one ring each way
   (lock-screen + force-quit variants) before calling it done.

## Rules that keep the residue from recurring

- The test rig lives in `/tmp` and dies at session end (§B) — never let a
  scratch daemon outlive its session: a stale daemon on a scratch profile
  rewrites the profile's `state.json` from stale in-memory state (#54 did
  exactly this: an Oct-11 daemon clobbered the E2E pairing).
- Only sandbox APNs + a test token on the LAN. The real `.p8` and production
  tokens stay off test command lines once §C is live.
- A rig that rings phones is wired to the apps; tearing down the daemon half
  without the `defaults`/launch-arg half leaves an app pointing at nothing.
