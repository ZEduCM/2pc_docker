# Declara um parâmetro do tipo [switch].
# Se o script for chamado com -PruneData, a variável $PruneData será $true.
param(
    [switch]$PruneData
)

# Configura o PowerShell para parar a execução em caso de erro.
$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if ($PruneData.IsPresent) {
    # Se o switch -PruneData foi usado na chamada do script
    Write-Host "Parando containers e removendo volumes de dados..."
    docker compose down -v
}
else {
    # Caso contrário, executa o comando padrão
    Write-Host "Parando containers..."
    docker compose down
}

Write-Host "Operação concluída."