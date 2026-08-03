# INCIDENT — minisforum-c host down (dev env offline) — OPEN

**Opened:** 2026-07-24 ~21:50 +0200 (detected by user: "dev is down")
**Impact start:** 2026-07-24 16:24 +0200 (last k3s heartbeat from minisforum-c)

## Impact
- **Dev env (https://dev-eve.<public_domain> / <dev-tailscale-ip>:9000): DOWN** — the whole host, not the app.
- k3s node `minisforum-c`: NotReady. Longhorn replicas on it degraded (rebuild elsewhere),
  monitoring daemonset pods gone, metallb speaker gone — cluster tolerates all.
- **Test + prod: UNAFFECTED** — their pods (incl. the ones that had been scheduled on
  minisforum-c) were rescheduled to k3s-x86-1/x86-2 within minutes of node loss; both serve
  v5.117.1. Two cosmetic `Terminating` pods remain pinned to the dead node.

## Evidence (2026-07-24 21:50 +0200)
- Cloudflare tunnel → 502; direct :9000 → timeout (tunnel host-side down).
- Tailscale <dev-tailscale-ip>: 100% packet loss (tailscaled dead).
- LAN <minisforum-lan-ip>: **ICMP answers**, but ALL TCP refused (22, 80, 445, 2222, 9000)
  → kernel alive, userspace services dead. Not a network partition.
- k3s: `Kubelet stopped posting node status` at 16:24:40 +0200; NotReady since 16:29.
- No recovery in 5+ hours → not a transient; box is wedged (failed boot / OOM cascade /
  possibly a CachyOS rolling-update casualty).

## Timeline context
- 16:0x–16:2x: routine dev deploy (v5.117.1 docker-compose build) + read-only in-container
  harness ran successfully — last known-good interactions.
- 16:24: heartbeat stops. Correlation noted, but the operations were routine (same commands
  run many times today); no known mechanism for them to take down the host.

## Required action
- **Physical power cycle of the minisforum** (no IPMI/remote power known). After boot:
  1. `docker-compose ps` in ~/docker/eve_esi_app — dev app should come up with data intact
     (SQLite on a docker volume).
  2. Check why it died: `journalctl -b -1 -p err`, disk space, pacman log (CachyOS updates).
  3. Confirm k3s node returns Ready + Longhorn replicas rebuild + Terminating pods clear.
  4. Verify https://dev-eve.<public_domain> serves 5.117.1.

## Close-out
Archive this file to ~/claude/kubernetes/docs/incidents/ when resolved.

## RESOLVED — 2026-07-24 21:55 +0200
Root cause: CachyOS system patch — the post-update reboot hung mid-boot (kernel+network up,
services never started). User power-cycled; box came back on kernel 7.1.4-1-cachyos.
Post-reboot checks ALL PASS: dev serves 5.117.1 (public URL), both containers up, archive
cycles clean (0 errors), k3s node Ready, 0 leftover Terminating pods, 0 degraded Longhorn
volumes. Total dev downtime ~5h40m; test/prod unaffected throughout.

---

## RESOLVED 2026-07-24 21:54 +0200

User power-cycled the box; clean boot on kernel 7.1.4-1-cachyos, node Ready, all services
back (dev env included). Root cause + full analysis in the canonical post-mortem:
**`2026-07-24-minisforum-shutdown-hang-2-multipathd.md`** (same host, same incident, wider
blast radius): shutdown hang #2 — systemd killed Longhorn instance-managers before CSI
unmounts → D-state; watchdog was disabled by CachyOS defaults (now armed: sp5100_tco,
self-resets in <=10 min). Prevention: drain-before-reboot in 80-upgrade-packages.yml.
Follow-on same evening: post-pacman open-iscsi rejected old node records → volume attaches
wedged on this host (fixed, see improvement-plan #66).
