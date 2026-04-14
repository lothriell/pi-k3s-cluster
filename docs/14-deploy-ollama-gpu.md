# 14 — Deploy Ollama on GPU Server

## Overview

Self-hosted LLM serving using Ollama on a dedicated GPU server (RTX 3090, 24GB VRAM).
The EVE Tracker app on K8s connects to Ollama via Tailscale for AI-powered trade analysis.

## Architecture

```
Browser → Cloudflare → K8s Cluster (Raspberry Pi)
                         ├── Frontend (Nginx + React)
                         └── Backend (Express + SQLite)
                                │
                                ├── ESI API (internet) — market data
                                └── Ollama (GPU server via Tailscale) — AI trade advisor
```

- **K8s cluster** — runs the web app (no GPU needed)
- **GPU server** — runs Ollama only, reachable via Tailscale mesh
- **No public exposure** — Ollama listens only on Tailscale IP

## Why This Split

| Concern | Decision |
|---|---|
| Pi cluster has no GPU | AI runs on dedicated GPU server |
| Network latency? | Irrelevant — LLM inference takes seconds, network adds ms |
| Security | Ollama only on Tailscale, never exposed publicly |
| Independence | Restart/update Ollama without touching the app |
| K8s simplicity | No GPU drivers or NVIDIA runtime on the cluster |

## Technology Choice: Why Ollama

Evaluated Ollama vs vLLM vs LM Studio:

| Criterion | Ollama | vLLM | LM Studio |
|---|---|---|---|
| Ansible automation | Excellent | Good | Poor |
| Headless server | Native daemon | Native | Desktop app (needs hacks) |
| RTX 3090 (24GB) | Graceful CPU offload | Crashes if model won't fit | Same as Ollama |
| Docker support | Official image | Official image | None |
| Model management | `ollama pull` CLI/API | HuggingFace manual | GUI-first |
| Concurrent throughput | Queued (fine for 1 user) | Excellent (overkill) | Queued |
| Quantization | GGUF | AWQ, GPTQ, GGUF | GGUF |

**Ollama wins** because:
- Docker + env vars = trivial Ansible automation
- Graceful partial CPU offload when VRAM is tight
- Single-user app doesn't need vLLM's batching
- LM Studio is a desktop tool, not suited for headless servers

## Recommended Model

**Primary: Qwen 2.5 32B Instruct (Q4_K_M)**
- ~20GB VRAM, tight but works on 24GB with partial CPU offload
- Excellent at structured/numerical data analysis
- Best reasoning capability that fits the hardware

**Fallback: Qwen 2.5 14B Instruct (Q5_K_M)**
- ~12GB VRAM, plenty of headroom
- Still very strong at math/tabular reasoning
- Faster inference, useful if 32B is too slow

## Prerequisites

1. Linux server with NVIDIA RTX 3090
2. NVIDIA drivers + NVIDIA Container Toolkit installed
3. Docker installed
4. Tailscale connected to the same tailnet as K8s nodes

## Deployment

### Automated (Ansible)

```bash
# From the repo root
ansible-playbook ansible/playbooks/09-deploy-ollama.yml
```

See `ansible/roles/ollama/` for the full role.

### Manual (Docker)

```bash
docker run -d \
  --name ollama \
  --runtime nvidia \
  --restart unless-stopped \
  -e NVIDIA_VISIBLE_DEVICES=all \
  -e OLLAMA_HOST=0.0.0.0:11434 \
  -e OLLAMA_FLASH_ATTENTION=1 \
  -e OLLAMA_KEEP_ALIVE=10m \
  -p 11434:11434 \
  -v ollama_data:/root/.ollama \
  ollama/ollama

# Pull the model
docker exec ollama ollama pull qwen2.5:32b-instruct-q4_K_M
```

## Connecting from EVE Tracker

The Express backend calls Ollama's OpenAI-compatible API:

```javascript
// In eve-tracking-jobs backend
const response = await axios.post(
  `http://${OLLAMA_TAILSCALE_IP}:11434/v1/chat/completions`,
  {
    model: 'qwen2.5:32b-instruct-q4_K_M',
    messages: [
      { role: 'system', content: 'You are an EVE Online trade advisor...' },
      { role: 'user', content: 'Given this market data: ...' }
    ],
    temperature: 0.3
  }
);
```

Add to EVE Tracker `.env`:
```
OLLAMA_URL=http://<gpu-tailscale-ip>:11434
OLLAMA_MODEL=qwen2.5:32b-instruct-q4_K_M
```

## Verification

```bash
# Health check
curl http://<tailscale-ip>:11434/api/tags

# Test inference
curl http://<tailscale-ip>:11434/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen2.5:32b-instruct-q4_K_M","messages":[{"role":"user","content":"Hello"}]}'
```

## VRAM Considerations

| Model | Quant | VRAM | Context 4K | Context 8K | Context 16K |
|---|---|---|---|---|---|
| Qwen 2.5 32B | Q4_K_M | ~20GB | OK | Tight | Partial CPU offload |
| Qwen 2.5 14B | Q5_K_M | ~12GB | OK | OK | OK |

If VRAM is tight, Ollama automatically offloads layers to CPU. Control with:
- `OLLAMA_NUM_GPU` — limit GPU layers
- `num_ctx` in API request — limit context window (default 2048, max varies)

For the trading use case, 4K-8K context is sufficient (market data tables + prompt).
