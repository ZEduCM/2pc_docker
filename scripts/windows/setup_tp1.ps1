# Declara os parâmetros que o script aceita. -NoBuild é um switch.
param(
    [switch]$NoBuild
)

# Configurações de "modo estrito" do PowerShell, similar ao 'set -euo pipefail' do Bash
$ErrorActionPreference = "Stop" # Para o script em caso de erro
Set-StrictMode -Version Latest # Garante que variáveis não inicializadas causem erro

# --- Variáveis Iniciais ---
$Token = "eyJhbGciOiJIUzI1NiIsInRpyCI6IkpXVCJ9.eyJzdWIiOiJ0ZXN0ZXIiLCJpYXQiOjE3NTk3OTU3MzcsImV4cCI6MTc5MTMzMTczN30.wkw6HfDEixe9F409vmtz0ldElcLAxmutXi4nWsUmFy8"
$ApiHeaders = @{
    "Authorization" = "Bearer $Token"
    "Content-Type"  = "application/json"
}

# --- Inicialização dos Containers ---
if ($NoBuild.IsPresent) {
    Write-Host "Iniciando containers sem build..."
    docker compose up -d
}
else {
    Write-Host "Fazendo build e iniciando containers..."
    docker compose up -d --build
}

# --- Função de Healthcheck ---
function Wait-Url {
    param(
        [string]$Url
    )
    
    Write-Host "Aguardando healthcheck para: $Url"
    foreach ($i in 1..60) {
        try {
            # Invoke-WebRequest silencia o output e joga o erro fora se falhar
            Invoke-WebRequest -Uri $Url -UseBasicParsing | Out-Null
            Write-Host "$Url está disponível."
            return # Sai da função com sucesso
        }
        catch {
            # Se der erro, espera 1 segundo e tenta de novo
            Start-Sleep -Seconds 1
        }
    }
    # Se o loop terminar, o timeout foi atingido
    Write-Error "Timeout no healthcheck: $Url"
    exit 1
}

Wait-Url "http://localhost:8080/healthz"
Wait-Url "http://localhost:8001/healthz"
Wait-Url "http://localhost:8002/healthz"
Write-Host "Todos os serviços estão online."

# --- Execução dos Testes ---

# Saldos iniciais (Invoke-RestMethod já converte o JSON para um objeto PowerShell)
$balA0 = Invoke-RestMethod -Uri "http://localhost:8001/balance"
$balB0 = Invoke-RestMethod -Uri "http://localhost:8002/balance"

# 1) Transferência OK + Idempotência
Write-Host "1) Testando transferência OK e idempotência..."
$k1 = [guid]::NewGuid().ToString()
$body1 = @{
    from_account    = "A"
    to_account      = "B"
    amount          = 50
    idempotency_key = $k1
} | ConvertTo-Json -Compress

$res1 = Invoke-RestMethod -Method Post -Uri "http://localhost:8080/transfer" -Headers $ApiHeaders -Body $body1
$res1b = Invoke-RestMethod -Method Post -Uri "http://localhost:8080/transfer" -Headers $ApiHeaders -Body $body1

$idemOk = if ($res1.transaction_id -eq $res1b.transaction_id) { "true" } else { "false" }
Write-Host "Verificação de idempotência: $idemOk"

# 2) Crash coordenador após PREPARE → recovery (rollback)
Write-Host "2) Testando crash do coordenador (requisição irá falhar)..."
$k2 = [guid]::NewGuid().ToString()
$body2 = @{
    from_account    = "A"
    to_account      = "B"
    amount          = 10
    idempotency_key = $k2
    simulate        = @{ crash_coordinator_after_prepare = $true }
} | ConvertTo-Json -Compress

# Usamos try/catch para ignorar o erro esperado de "Connection reset"
try {
    Invoke-RestMethod -Method Post -Uri "http://localhost:8080/transfer" -Headers $ApiHeaders -Body $body2
} catch {
    Write-Warning "A requisição falhou como esperado (crash do coordenador)."
}
Write-Host "Aguardando 12 segundos para o processo de recovery..."
Start-Sleep -Seconds 12

# 3) Crash participante A após PREPARE → abort/rollback
Write-Host "3) Testando crash do participante A (requisição irá retornar erro)..."
$k3 = [guid]::NewGuid().ToString()
$body3 = @{
    from_account    = "A"
    to_account      = "B"
    amount          = 10
    idempotency_key = $k3
    simulate        = @{ crash_participant = @{ name = "A"; stage = "after_prepare" } }
} | ConvertTo-Json -Compress

# Usamos try/catch para ignorar o erro HTTP 409 (Conflict) esperado
try {
    Invoke-RestMethod -Method Post -Uri "http://localhost:8080/transfer" -Headers $ApiHeaders -Body $body3
} catch {
    Write-Warning "A transação foi abortada como esperado (crash do participante)."
}
Write-Host "Aguardando 8 segundos..."
Start-Sleep -Seconds 8


# --- Coleta de Dados Finais ---
# Saldos finais
$balA1 = Invoke-RestMethod -Uri "http://localhost:8001/balance"
$balB1 = Invoke-RestMethod -Uri "http://localhost:8002/balance"

# Métricas
$metAPI = Invoke-RestMethod -Uri "http://localhost:8080/metrics"
$metA = Invoke-RestMethod -Uri "http://localhost:8001/metrics"
$metB = Invoke-RestMethod -Uri "http://localhost:8002/metrics"

# --- Resumo ---
Write-Host ""
Write-Host "==== RESUMO ===="
# Acessa diretamente a propriedade .balance do objeto retornado
Write-Host "A: $($balA0.balance) → $($balA1.balance)"
Write-Host "B: $($balB0.balance) → $($balB1.balance)"

Write-Host "--- Métricas API ---"
$metAPI

Write-Host "--- Métricas A ---"
$metA

Write-Host "--- Métricas B ---"
$metB

# Logs (curtos)
Write-Host "--- Últimos logs ---"
# O || true do bash é para ignorar erros. Um try/catch faz o mesmo em PowerShell.
try {
    docker compose logs --no-color --tail=20
} catch {
    Write-Warning "Não foi possível obter os logs do Docker."
}