#!/usr/bin/env bash
set -euo pipefail

NOBUILD=0
if [[ "${1:-}" == "--no-build" ]]; then
  NOBUILD=1
fi

TOKEN="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ0ZXN0ZXIiLCJpYXQiOjE3NTk3OTU3MzcsImV4cCI6MTc5MTMzMTczN30.wkw6HfDEixe9F409vmtz0ldElcLAxmutXi4nWsUmFy8"

if [[ $NOBUILD -eq 1 ]]; then
  docker compose up -d
else
  docker compose up -d --build
fi

echo "Aguardando healthchecks..."
wait_url() {
  local url="$1"
  for i in {1..60}; do
    if curl -fsS "$url" >/dev/null; then return 0; fi
    sleep 1
  done
  echo "Timeout no healthcheck: $url" >&2
  exit 1
}

wait_url http://localhost:8080/healthz
wait_url http://localhost:8001/healthz
wait_url http://localhost:8002/healthz

# Saldos iniciais
balA0=$(curl -fsS http://localhost:8001/balance)
balB0=$(curl -fsS http://localhost:8002/balance)

uuid() { cat /proc/sys/kernel/random/uuid; }

# 1) Transferência OK + idempotência
k1=$(uuid)
if command -v jq >/dev/null 2>&1; then
  body1=$(jq -n --arg k "$k1" '{from_account:"A", to_account:"B", amount:50, idempotency_key:$k}')
else
  body1='{"from_account":"A","to_account":"B","amount":50,"idempotency_key":"'"$k1"'"}'
fi
res1=$(curl -fsS -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d "$body1" http://localhost:8080/transfer)
res1b=$(curl -fsS -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d "$body1" http://localhost:8080/transfer)

idem_ok="?"
if command -v jq >/dev/null 2>&1; then
  id1=$(echo "$res1" | jq -r .transaction_id)
  id2=$(echo "$res1b" | jq -r .transaction_id)
  [[ "$id1" == "$id2" ]] && idem_ok="true" || idem_ok="false"
else
  echo "(Sugestão: instale jq para verificação de idempotência automática)"
  idem_ok="(verifique manualmente)"
fi

# 2) Crash coordenador após PREPARE → recovery (rollback)
k2=$(uuid)
if command -v jq >/dev/null 2>&1; then
  body2=$(jq -n --arg k "$k2" '{from_account:"A", to_account:"B", amount:10, idempotency_key:$k, simulate:{crash_coordinator_after_prepare:true}}')
else
  body2='{"from_account":"A","to_account":"B","amount":10,"idempotency_key":"'"$k2"'" ,"simulate":{"crash_coordinator_after_prepare":true}}'
fi
set +e
curl -fsS -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d "$body2" http://localhost:8080/transfer >/dev/null 2>&1
set -e
sleep 12

# 3) Crash participante A após PREPARE → abort/rollback
k3=$(uuid)
if command -v jq >/dev/null 2>&1; then
  body3=$(jq -n --arg k "$k3" '{from_account:"A", to_account:"B", amount:10, idempotency_key:$k, simulate:{crash_participant:{name:"A", stage:"after_prepare"}}}')
else
  body3='{"from_account":"A","to_account":"B","amount":10,"idempotency_key":"'"$k3"'" ,"simulate":{"crash_participant":{"name":"A","stage":"after_prepare"}}}'
fi
set +e
curl -fsS -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d "$body3" http://localhost:8080/transfer >/dev/null 2>&1
set -e
sleep 8

# Saldos finais
balA1=$(curl -fsS http://localhost:8001/balance)
balB1=$(curl -fsS http://localhost:8002/balance)

# Métricas
metAPI=$(curl -fsS http://localhost:8080/metrics)
metA=$(curl -fsS http://localhost:8001/metrics)
metB=$(curl -fsS http://localhost:8002/metrics)

# Resumo
printf "
==== RESUMO ====
"
if command -v jq >/dev/null 2>&1; then
  printf "A: %s → %s
" "$(echo "$balA0" | jq -r .balance)" "$(echo "$balA1" | jq -r .balance)"
  printf "B: %s → %s
" "$(echo "$balB0" | jq -r .balance)" "$(echo "$balB1" | jq -r .balance)"
else
  echo "Saldo A inicial: $balA0"
  echo "Saldo B inicial: $balB0"
  echo "Saldo A final:   $balA1"
  echo "Saldo B final:   $balB1"
fi
printf -- "--- Métricas API ---
%s
" "$metAPI"
printf -- "--- Métricas A ---
%s
" "$metA"
printf -- "--- Métricas B ---
%s
" "$metB"

# Logs (curtos)
echo "--- Últimos logs ---"
(docker compose logs --no-color --tail=20 || true)