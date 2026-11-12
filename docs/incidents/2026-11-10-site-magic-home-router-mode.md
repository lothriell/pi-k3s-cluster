# Incident — Site Magic tunnel down: home ISP router flipped bridge → router mode

**Status:** Resolved 2026-11-11 (carrier restored bridge mode; tunnel back ~07:36Z, ~27 h down)
**Severity:** High
**Opened:** 2026-11-10 05:19 CET (04:19Z)
**Discovered by:** RemoteSiteLinkDown page + user (UniFi dashboard), session 2026-11-10
**Impact:** k3s-x86-1/2 NotReady, AMP game-server monitoring blind, Wazuh unreachable from home;
16 of 17 Longhorn volumes degraded (home replica only). All home-side workloads keep serving.

## Resolution

The carrier switched the home ISP router back to bridge mode overnight 11-10 → 11-11; the HOME UCG got its
public WAN IP back and Site Magic re-peered by ~07:36Z (RemoteSiteLinkDown resolved). x86-1/2 rejoined Ready and all
16 degraded Longhorn volumes rebuilt to healthy without intervention (loki included). Knock-on: g-02's ADS panel
crashed during the outage and needed a manual start; two release-watcher runs failed on the GitHub rate limit.
No data loss; nightly backups ran on both nights.

## Symptom

- 04:19Z: RemoteSiteLinkDown, NodeDown ×2, KubeNodeNotReady, AmpAdsDown ×3, AmpExporterDown — all at once.
- User saw "site down, UCG responds, servers behind it don't".
- Public eve probes dipped ~2 min at 04:19–04:20Z (home WAN blip), then recovered.

## Diagnosis

- Remote hosts were never down: k3s-x86-1/2, wazuh-server, lab (pve-1), ubuntu-g-* all answer
  `tailscale ping` (via DERP — both sites now NATed). x86-1 uptime 11 days.
- From inside k3s-x86-1: own gateway, x86-2, pve-1, 1.1.1.1 reachable; the home gateway / rpi-k3s-1 / API VIP not.
  From home: nothing in the remote subnet. → the site-to-site tunnel itself is dead, both directions.
- Site Manager → SD-WAN banner: **"Site Magic <magic-site-name> must include at least one gateway with a public IP."**
  HOME UCG WAN = `<home-ucg-wan-cgnat-ip>` (100.64.0.0/10, not public); REMOTE UCG WAN = `<remote-ucg-wan-private-ip>`
  (always behind its ISP router's NAT). HOME used to hold the public IP and carry the tunnel.
- **Root cause (user, confirmed with carrier):** a morning firmware upgrade on the home ISP router
  switched it from **bridge to router mode**, so the HOME UCG lost its public WAN IP. Toggling Site Magic
  cannot fix this.

## Actions taken

- No routing workaround: Longhorn/Flannel over Tailscale would need `accept-routes` on cluster nodes
  (breaks Flannel/MetalLB) and would crawl over DERP. Decision: wait for the bridge-mode switch.
- Risk mitigation — on-demand Longhorn backups to R2 (`default` target), all Completed ~07:00Z,
  Snapshot + Backup CRs named `ondemand-1110-<x>`: vw-data, vw-att, authentik-pg, eve-prod, eve-test,
  gitea, forgejo, netbox-pg, dojo-pg. (Nightly backups had also run 02:00–02:17Z, before the drop.)

## Next steps

- [x] (link back ~07:36Z 2026-11-11 — RemoteSiteLinkDown resolved) After the carrier restores bridge mode: HOME UCG WAN shows a public IP, Site Magic re-peers.
- [x] (verified 2026-11-11 ~10:00 CET: both x86 Ready, 17/17 volumes healthy) x86 nodes Ready; watch the 16 Longhorn rebuilds (incremental vs full not confirmed; loki 22 GB is the
      one that can loop cross-site).
- [x] Aftermath 2026-11-11: g-02 AMP panel ADS01 (still AMP 2.8.0.8) crashed 02:30 VM time on an unhandled
      exception in its template git update (`DownloadFromGit` ArgumentException) and stayed down → AmpAdsDown +
      AmpTargetUnreachable; started by hand (`ampinstmgr start ADS01`, :8081 up). Two release-watcher job pods failed
      11-10 07:01Z (GitHub rate-limited during the outage) → PodNotReady; deleted, later runs had completed. 0 firing.
- [x] (2026-11-11; vw-data snapshot CR needed its finalizer cleared — engine had already marked it removed but did not
      coalesce it within 10 min) Delete the 9 `ondemand-1110-*` Backup + Snapshot CRs once replicas are healthy (outside recurring-job retention).
- [x] Archive to `docs/incidents/2026-11-10-site-magic-home-router-mode.md`.
- [x] Follow-ups tracked in improvement-plan **#88** (redundancy + detection still open there).
