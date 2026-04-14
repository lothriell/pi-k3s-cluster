# 15 — Deploy Open WebUI

## Overview

Open WebUI provides a ChatGPT-like web interface for interacting with LLMs served by Ollama. It runs on K8s and connects to the Ollama GPU server via a Traefik-proxied external service.

## Architecture

```
Browser → chat.<local_domain> → Traefik (MetalLB VIP)
  → open-webui pod (K8s, port 8080)
    → ollama-external service (K8s)
      → Ollama GPU server (Docker, port 11434)
```

## Prerequisites

1. Ollama deployed and running (see `docs/14-deploy-ollama-gpu.md`)
2. Ollama external service created (in `k8s/ingress/local-ingress.yml`)
3. DNS entry for `chat.<local_domain>` pointing to Traefik LB IP

## Deployment

```bash
kubectl apply -f k8s/open-webui/open-webui.yml
```

This creates:
- `open-webui` namespace
- 2Gi PVC for SQLite database (conversation history)
- Deployment with Open WebUI container
- Service + Ingress for `chat.<local_domain>`

## First-Time Setup

1. Open `http://chat.<local_domain>` in your browser
2. Create your admin account (first signup becomes admin)
3. Disable further signups:
   ```bash
   kubectl set env deployment/open-webui -n open-webui ENABLE_SIGNUP=false
   ```
4. Select a model from the dropdown (models are auto-discovered from Ollama)

## Configuration

Key environment variables (set in the manifest):

| Variable | Value | Purpose |
|----------|-------|---------|
| `OLLAMA_BASE_URL` | `http://ollama-external.default.svc.cluster.local:11434` | Ollama API endpoint |
| `RAG_EMBEDDING_ENGINE` | `ollama` | Offload embeddings to Ollama (saves RAM) |
| `AUDIO_STT_ENGINE` | `openai` | Prevents loading local STT model |
| `ENABLE_SIGNUP` | `true` | Allow account creation (disable after first user) |

## Resource Requirements

| Resource | Request | Limit |
|----------|---------|-------|
| CPU | 100m | 1 core |
| Memory | 512Mi | 1Gi |

Open WebUI OOMKills at 512Mi limit on ARM64 during startup — 1Gi is required.

## Password Reset

If you lose your password:

```bash
kubectl exec -n open-webui deploy/open-webui -- python3 -c "
import sqlite3, bcrypt
new_password = 'YOUR_NEW_PASSWORD'
hashed = bcrypt.hashpw(new_password.encode(), bcrypt.gensalt()).decode()
conn = sqlite3.connect('/app/backend/data/webui.db')
users = conn.execute('SELECT id, email FROM user').fetchall()
for u in users: print(f'id={u[0]} email={u[1]}')
conn.execute('UPDATE auth SET password = ?', (hashed,))
conn.commit()
print('Password updated')
"
```

## Nuke and Rebuild

On `make nuke && make all`, Open WebUI is NOT part of the Ansible chain. Redeploy manually:

```bash
kubectl apply -f k8s/open-webui/open-webui.yml
```

Conversation history survives if the Longhorn PVC is preserved. If starting fresh, create a new admin account and disable signup again.

## Troubleshooting

**Bad Gateway:** Open WebUI takes ~2 minutes to start on ARM64 (database migrations + dependency loading). Wait and retry.

**OOMKilled:** Increase memory limit. 1Gi is the minimum for ARM64.

**Model not showing:** Verify Ollama is reachable:
```bash
kubectl exec -n open-webui deploy/open-webui -- curl -s http://ollama-external.default.svc.cluster.local:11434/api/tags
```
