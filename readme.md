# TP1: 2PC (Two‑Phase Commit) Bank Transfer

## 🧭 Objetivo Geral

Implementar o **protocolo de Two‑Phase Commit (2PC)** em um ambiente distribuído, explorando:

- Coordenação entre processos e tolerância a falhas.
- Idempotência de requisições.
- Observabilidade e monitoramento via métricas.
- Orquestração completa via **Docker Compose**.

---

## ⚙️ Requisitos

- Docker e Docker Compose (testado em v2.26+)
- Python 3.11 (para ambiente local, opcional)
- `curl` (para healthchecks internos)
- `jq` (opcional, melhora legibilidade de testes em Linux)

---

## 🚀 Subir e Derrubar a Stack

```bash
# Sobe todos os serviços (com build)
docker compose up -d --build

# Derruba (mantém volumes)
docker compose down

# Derruba e limpa dados (volumes)
docker compose down -v
```

### Serviços Sobe (via compose.yaml)

| Serviço   | Porta | Função                    | Saúde            |
| --------- | ----- | ------------------------- | ---------------- |
| api       | 8080  | Coordenador 2PC (FastAPI) | `/healthz`       |
| account-a | 8001  | Participante A            | `/healthz`       |
| account-b | 8002  | Participante B            | `/healthz`       |
| redis     | 6379  | Backend de coordenação    | `redis-cli ping` |

---

## 🔄 Testes Automatizados

### Linux

```bash
chmod +x scripts/*.sh
./scripts/setup_tp1.sh
./scripts/cleanup_tp1.sh --prune-data
```

### Windows (PowerShell)

```powershell
./scripts/setup_tp1.ps1
./scripts/cleanup_tp1.ps1 -PruneData
```

---

## 🧪 Testes Manuais

```bash
# Token JWT (HS256, dev)
TOKEN="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ0ZXN0ZXIiLCJpYXQiOjE3NTk3OTU3MzcsImV4cCI6MTc5MTMzMTczN30.wkw6HfDEixe9F409vmtz0ldElcLAxmutXi4nWsUmFy8"

# Saldos iniciais
curl -s http://localhost:8001/balance | jq .
curl -s http://localhost:8002/balance | jq .

# Transferência bem-sucedida + idempotência
curl -s -X POST http://localhost:8080/transfer \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"from_account":"A","to_account":"B","amount":50,"idempotency_key":"t1"}' | jq .

# Simular crash coordenador após prepare (recovery → rollback)
curl -s -X POST http://localhost:8080/transfer \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"from_account":"A","to_account":"B","amount":10,"simulate":{"crash_coordinator_after_prepare":true}}'
```

---

## 🧩 Notas de Projeto e Decisões

### Arquitetura

- **Coordenador (API FastAPI)** — controla o fluxo 2PC.
- **Participantes (A/B)** — gerenciam saldos e logs locais.
- **Redis** — provê locks e log global de transações.

### Protocolo / Algoritmo (2PC Simplificado)

1. **Prepare Phase:** o coordenador envia `prepare` para A e B.
2. **Commit Phase:** se ambos responderem `OK`, envia `commit`.
3. Em caso de falha, executa `rollback` idempotente.
4. Logs são persistidos no Redis e nos arquivos dos participantes.

### Idempotência e Locks

- `idempotency_key` evita duplicação de operações.
- Locks Redis (`lock:pair:A:B`) previnem corrida entre transferências.

### Tratamento de Falhas

- Crash coordenador → recovery loop reverte transações “PREPARED\_ALL”.
- Crash participante → rollback seguro em reenvios.
- Participantes usam persistência local (`state.json`) para retomada.

### Observabilidade

- `/metrics` em todos os serviços.
- Healthchecks automáticos via Compose.
- Logs disponíveis via `docker compose logs -f`.

### Segurança

- JWT HS256 (dev) protege `/transfer`.
