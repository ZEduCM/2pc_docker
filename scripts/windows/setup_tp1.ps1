param(
  [switch]$NoBuild
)

$ErrorActionPreference = "Stop"
$TOKEN = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ0ZXN0ZXIiLCJpYXQiOjE3NTk3OTU3MzcsImV4cCI6MTc5MTMzMTczN30.wkw6HfDEixe9F409vmtz0ldElcLAxmutXi4nWsUmFy8"

if (!$NoBuild) {
  docker compose up -d --build
} else {
  docker compose up -d
}

Write-Host "Aguardando healthchecks..."
function Wait-URL($url) {
  for ($i=0; $i -lt 60; $i++) {
    try { Invoke-RestMethod -Uri $url -TimeoutSec 2 | Out-Null; return } catch { Start-Sleep -Seconds 1 }
  }
  throw "Timeout no healthcheck: $url"
}

Wait-URL http://localhost:8080/healthz
Wait-URL http://localhost:8001/healthz
Wait-URL http://localhost:8002/healthz

# Saldos iniciais
$balA0 = Invoke-RestMethod http://localhost:8001/balance
$balB0 = Invoke-RestMethod http://localhost:8002/balance

# 1) Transferência OK + idempotência
$k1 = [Guid]::NewGuid().ToString()
$body1 = @{ from_account="A"; to_account="B"; amount=50; idempotency_key=$k1 } | ConvertTo-Json
$res1 = Invoke-RestMethod -Uri http://localhost:8080/transfer -Method POST -Headers @{Authorization="Bearer $TOKEN"} -ContentType application/json -Body $body1
$res1b = Invoke-RestMethod -Uri http://localhost:8080/transfer -Method POST -Headers @{Authorization="Bearer $TOKEN"} -ContentType application/json -Body $body1
$idem_ok = ($res1.transaction_id -eq $res1b.transaction_id)

# 2) Crash coordenador após PREPARE → recovery (rollback)
$k2 = [Guid]::NewGuid().ToString()
$sim2 = @{ from_account="A"; to_account="B"; amount=10; idempotency_key=$k2; simulate=@{ crash_coordinator_after_prepare=$true } } | ConvertTo-Json
try { Invoke-RestMethod -Uri http://localhost:8080/transfer -Method POST -Headers @{Authorization="Bearer $TOKEN"} -ContentType application/json -Body $sim2 | Out-Null } catch { }
Start-Sleep -Seconds 12

# 3) Crash participante A após PREPARE → abort/rollback
$k3 = [Guid]::NewGuid().ToString()
$sim3 = @{ from_account="A"; to_account="B"; amount=10; idempotency_key=$k3; simulate=@{ crash_participant=@{ name="A"; stage="after_prepare" } } } | ConvertTo-Json
try { Invoke-RestMethod -Uri http://localhost:8080/transfer -Method POST -Headers @{Authorization="Bearer $TOKEN"} -ContentType application/json -Body $sim3 | Out-Null } catch { }
Start-Sleep -Seconds 8

# Saldos finais
$balA1 = Invoke-RestMethod http://localhost:8001/balance
$balB1 = Invoke-RestMethod http://localhost:8002/balance

# Métricas
$metAPI = Invoke-RestMethod http://localhost:8080/metrics
$metA = Invoke-RestMethod http://localhost:8001/metrics
$metB = Invoke-RestMethod http://localhost:8002/metrics

# Resumo
Write-Host "==== RESUMO ====" -ForegroundColor Cyan
Write-Host ("A: {0} → {1}" -f $balA0.balance, $balA1.balance)
Write-Host ("B: {0} → {1}" -f $balB0.balance, $balB1.balance)
Write-Host ("Idempotência (k1) OK: {0}" -f $idem_ok)
Write-Host "--- Métricas API ---" -ForegroundColor Yellow
Write-Host $metAPI
Write-Host "--- Métricas A ---"
Write-Host $metA
Write-Host "--- Métricas B ---"
Write-Host $metB

# Logs (curtos)
Write-Host "--- Últimos logs ---" -ForegroundColor Yellow
try { docker compose logs --no-color --tail=50 } catch { }