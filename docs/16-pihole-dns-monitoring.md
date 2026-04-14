# 16 — Pi-hole DNS Monitoring & Alerting

## Overview

Real-time DNS query monitoring with custom alerts and 3-month searchable log retention.

```
athena (Docker)
├── Pi-hole → pihole.log (volume mounted to host)
├── Promtail → ships ALL logs to Loki (3-month retention)
├── ntfy → push notifications to phone
└── pihole-dns-monitor (systemd) → pattern matching → ntfy alerts

K8s cluster
├── Loki (log aggregation, 3-month retention, 10Gi PVC)
└── Grafana (Loki datasource for DNS log search)
```

## What Gets Monitored

| Layer | Scope | Purpose |
|-------|-------|---------|
| **Promtail → Loki** | ALL queries, ALL IPs | Searchable log retention (3 months) |
| **Alert script → ntfy** | Specific rules only | Real-time notifications to phone |

## Alert Rules

Rules live in `secrets/pihole-alert-rules.conf` (gitignored). Format:

```
# domain_pattern | ip_or_* | display_label
*.sme.sk | 10.0.0.42 | duck domain          # alert only for this IP
*.facebook.com | * | social media            # alert for ANY IP
bad-site.org | 10.0.0.42 | phishing          # exact domain + specific IP
```

When `10.0.0.42` queries `news.sme.sk`, your phone gets:
- **Title:** User 10.0.0.42 accessed duck domain
- **Body:** Domain: news.sme.sk / Client: 10.0.0.42 / Label: duck domain

## Deployment

### Prerequisites
- Pi-hole running in Docker on athena
- K8s cluster with Grafana in monitoring namespace

### Deploy everything
```bash
ansible-playbook ansible/playbooks/10-deploy-pihole-monitor.yml
```

This will:
1. Mount pihole.log from the Pi-hole container to the host
2. Deploy ntfy + Promtail containers on athena
3. Deploy the monitoring script + systemd service on athena
4. Deploy Loki on K8s
5. (Manual) Update Grafana with Loki datasource: `helm upgrade grafana grafana/grafana -n monitoring -f k8s/monitoring/values-grafana.yml`

### Subscribe to alerts
1. Install [ntfy app](https://ntfy.sh) on your phone (Android/iOS)
2. Subscribe to topic `dns-alerts` at `http://<athena-ip>:8080`

## Day-to-Day Management

### Edit alert rules (directly on athena)
```bash
ssh athena
sudo nano /etc/pihole-monitor/alert-rules.conf
sudo systemctl reload pihole-dns-monitor
```

### Edit alert rules (from Mac, keeps local backup)
```bash
# Edit secrets/pihole-alert-rules.conf
ansible-playbook ansible/playbooks/10-deploy-pihole-monitor.yml
```

### Search DNS logs in Grafana
1. Open Grafana → Explore
2. Select **Loki** datasource
3. Query examples:
   ```
   {job="pihole"}                                    # all logs
   {job="pihole"} |= "10.0.0.42"                    # specific IP
   {job="pihole"} |= "sme.sk"                       # specific domain
   {job="pihole"} |= "query" |= "10.0.0.42"         # queries only from IP
   ```

### Check monitor service
```bash
ssh athena
sudo systemctl status pihole-dns-monitor
sudo journalctl -u pihole-dns-monitor -f    # live log
```

## Troubleshooting

**No alerts:** Check `sudo systemctl status pihole-dns-monitor` and verify rules file has correct format.

**ntfy not reachable:** Check `sudo docker ps | grep ntfy` on athena.

**Logs not in Grafana:** Verify Promtail is running (`sudo docker ps | grep promtail`) and Loki is healthy (`kubectl get pods -n monitoring -l app.kubernetes.io/name=loki`).

**Pi-hole broke after remount:** The playbook recreates the Pi-hole container with the additional log volume. If DNS stops working, check `sudo docker ps` and `sudo docker logs pihole`.
