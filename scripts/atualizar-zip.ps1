#requires -Version 5.1
<#
.SYNOPSIS
    Mantem o ioterminal-kit.zip da raiz do projeto sempre na versao mais recente.
.DESCRIPTION
    Compara a data do ZIP com a dos arquivos que entram no kit (installer, manifesto,
    atalho, documentacao do cliente, extrator embutido e pacotes). Se o ZIP estiver
    atualizado, nao faz nada. Se estiver velho ou ausente, remonta o kit chamando o
    preparar-kit.ps1 em pasta temporaria e substitui o ZIP.

    A montagem em si nao e duplicada aqui: quem monta continua sendo o preparar-kit.ps1.
.PARAMETER Forcar
    Regenera mesmo que o ZIP esteja atualizado.
.PARAMETER Hook
    Modo silencioso para uso pelo hook do Cursor: nao escreve texto no stdout
    (apenas o JSON vazio esperado pelo hook) e registra o resultado no log.
.EXAMPLE
    .\scripts\atualizar-zip.ps1
.EXAMPLE
    .\scripts\atualizar-zip.ps1 -Forcar
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [switch]$Forcar,

    [Parameter(Mandatory = $false)]
    [switch]$Hook
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$raiz = Split-Path -Parent $PSScriptRoot
$zipFinal = Join-Path $raiz 'ioterminal-kit.zip'
$logPath = Join-Path $raiz '.cursor\atualizar-zip.log'

function Write-Registro {
    param(
        [Parameter(Mandatory = $true)][string]$Mensagem,
        [Parameter(Mandatory = $false)][switch]$Erro
    )

    $linha = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'), $Mensagem

    try {
        $pastaLog = Split-Path -Parent $logPath
        if (-not (Test-Path -LiteralPath $pastaLog)) {
            New-Item -ItemType Directory -Path $pastaLog -Force | Out-Null
        }
        Add-Content -LiteralPath $logPath -Value $linha -Encoding UTF8

        # Log de conveniencia, nao de auditoria: manter curto.
        $conteudo = @(Get-Content -LiteralPath $logPath -ErrorAction SilentlyContinue)
        if ($conteudo.Count -gt 200) {
            $conteudo | Select-Object -Last 100 | Set-Content -LiteralPath $logPath -Encoding UTF8
        }
    }
    catch {
        # Falha de log nunca interrompe a atualizacao do ZIP.
    }

    if ($Hook) { return }

    if ($Erro) { Write-Warning $Mensagem } else { Write-Host $Mensagem }
}

function Get-ArquivosFonte {
    $fontes = @()

    foreach ($nome in @('installer.ps1', 'manifest.json', 'manifest.schema.json', 'README.md', 'PASSO-A-PASSO.txt')) {
        $caminho = Join-Path $raiz $nome
        if (Test-Path -LiteralPath $caminho) { $fontes += Get-Item -LiteralPath $caminho }
    }

    $atalho = Join-Path $PSScriptRoot 'iniciar-kit.cmd'
    if (Test-Path -LiteralPath $atalho) { $fontes += Get-Item -LiteralPath $atalho }

    $manifesto = Join-Path $raiz 'manifest.json'
    if (Test-Path -LiteralPath $manifesto) {
        $conteudo = Get-Content -LiteralPath $manifesto -Raw -Encoding UTF8 | ConvertFrom-Json

        if ($conteudo.PSObject.Properties.Name -contains 'bundledExtractor') {
            $pastaExtrator = Split-Path -Parent ([string]$conteudo.bundledExtractor.file)
            if ($pastaExtrator) {
                $caminho = Join-Path $raiz $pastaExtrator
                if (Test-Path -LiteralPath $caminho) {
                    $fontes += @(Get-ChildItem -LiteralPath $caminho -File -Recurse -ErrorAction SilentlyContinue)
                }
            }
        }

        if ($conteudo.PSObject.Properties.Name -contains 'packageRoot') {
            $caminho = Join-Path $raiz ([string]$conteudo.packageRoot)
            if (Test-Path -LiteralPath $caminho) {
                $fontes += @(Get-ChildItem -LiteralPath $caminho -File -Recurse -ErrorAction SilentlyContinue)
            }
        }
    }

    return $fontes
}

try {
    $fontes = @(Get-ArquivosFonte)
    if ($fontes.Count -eq 0) {
        Write-Registro -Mensagem 'Nenhum arquivo do kit encontrado: nada a fazer.' -Erro
        if ($Hook) { Write-Output '{}' }
        exit 0
    }

    $maisRecente = ($fontes | Sort-Object LastWriteTime -Descending | Select-Object -First 1)

    if (-not $Forcar -and (Test-Path -LiteralPath $zipFinal)) {
        $zip = Get-Item -LiteralPath $zipFinal
        if ($zip.LastWriteTime -ge $maisRecente.LastWriteTime) {
            Write-Registro -Mensagem "ZIP atualizado, nada a fazer (mais recente: $($maisRecente.Name))."
            if ($Hook) { Write-Output '{}' }
            exit 0
        }
    }

    $motivo = if (Test-Path -LiteralPath $zipFinal) { "alteracao em $($maisRecente.Name)" } else { 'ZIP ausente' }
    Write-Registro -Mensagem "Regerando o kit ($motivo)..."

    $staging = Join-Path $env:TEMP 'ioterminal-kit-build'
    $zipTemporario = Join-Path $env:TEMP 'ioterminal-kit-build.zip'

    foreach ($antigo in @($staging, $zipTemporario)) {
        if (Test-Path -LiteralPath $antigo) {
            Remove-Item -LiteralPath $antigo -Recurse -Force
        }
    }

    & (Join-Path $PSScriptRoot 'preparar-kit.ps1') -Destino $staging *>&1 | Out-Null

    if (-not (Test-Path -LiteralPath $zipTemporario)) {
        throw "preparar-kit.ps1 nao gerou o ZIP esperado em $zipTemporario"
    }

    Move-Item -LiteralPath $zipTemporario -Destination $zipFinal -Force
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue

    $mb = [math]::Round((Get-Item -LiteralPath $zipFinal).Length / 1MB, 2)
    Write-Registro -Mensagem "ZIP atualizado: $zipFinal ($mb MB)"

    if ($Hook) { Write-Output '{}' }
    exit 0
}
catch {
    Write-Registro -Mensagem "Falha ao atualizar o ZIP: $($_.Exception.Message)" -Erro

    # No hook o ZIP desatualizado nao deve travar o trabalho no editor.
    if ($Hook) {
        Write-Output '{}'
        exit 0
    }

    exit 1
}
