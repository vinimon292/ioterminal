#requires -Version 5.1
<#
.SYNOPSIS
    Monta a pasta do kit do IOTerminal e gera o ZIP para levar ao cliente.
.DESCRIPTION
    Copia installer.ps1, manifest.json, iniciar-kit.cmd e a pasta de pacotes
    (IOTERMINAL) para o destino, remove a marca de arquivo baixado da internet
    e compacta tudo em um ZIP ao lado da pasta.
.EXAMPLE
    .\scripts\preparar-kit.ps1 -Destino C:\ioterminal-kit
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Destino
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$raiz = Split-Path -Parent $PSScriptRoot
$manifesto = Join-Path $raiz 'manifest.json'

if (-not (Test-Path -LiteralPath $manifesto)) {
    throw "manifest.json nao encontrado em $raiz"
}

$conteudo = Get-Content -LiteralPath $manifesto -Raw -Encoding UTF8 | ConvertFrom-Json
$packageRoot = if ($conteudo.PSObject.Properties.Name -contains 'packageRoot') { [string]$conteudo.packageRoot } else { '' }

if (-not (Test-Path -LiteralPath $Destino)) {
    New-Item -ItemType Directory -Path $Destino -Force | Out-Null
}

foreach ($nome in @('installer.ps1', 'manifest.json', 'manifest.schema.json', 'README.md')) {
    $origem = Join-Path $raiz $nome
    if (Test-Path -LiteralPath $origem) {
        Copy-Item -LiteralPath $origem -Destination (Join-Path $Destino $nome) -Force
    }
}

Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'iniciar-kit.cmd') -Destination (Join-Path $Destino 'iniciar-kit.cmd') -Force

$passoAPasso = Join-Path $raiz 'PASSO-A-PASSO.txt'
if (Test-Path -LiteralPath $passoAPasso) {
    Copy-Item -LiteralPath $passoAPasso -Destination (Join-Path $Destino 'PASSO-A-PASSO.txt') -Force
}

$extrator = if ($conteudo.PSObject.Properties.Name -contains 'bundledExtractor') { $conteudo.bundledExtractor } else { $null }
if ($extrator) {
    $pastaExtrator = Split-Path -Parent ([string]$extrator.file)
    if ($pastaExtrator) {
        $origemExtrator = Join-Path $raiz $pastaExtrator
        if (-not (Test-Path -LiteralPath $origemExtrator)) {
            throw "Pasta do extrator embutido ausente: $origemExtrator"
        }

        $destinoExtrator = Join-Path $Destino $pastaExtrator
        if (Test-Path -LiteralPath $destinoExtrator) {
            Remove-Item -LiteralPath $destinoExtrator -Recurse -Force
        }
        Copy-Item -LiteralPath $origemExtrator -Destination $destinoExtrator -Recurse -Force
        Write-Host "Extrator embutido copiado: $destinoExtrator"
    }
}

if ($packageRoot) {
    $origemPacotes = Join-Path $raiz $packageRoot
    if (-not (Test-Path -LiteralPath $origemPacotes)) {
        throw "Pasta de pacotes ausente: $origemPacotes"
    }

    $destinoPacotes = Join-Path $Destino $packageRoot
    if (Test-Path -LiteralPath $destinoPacotes) {
        Remove-Item -LiteralPath $destinoPacotes -Recurse -Force
    }
    Copy-Item -LiteralPath $origemPacotes -Destination $destinoPacotes -Recurse -Force
    Write-Host "Pacotes copiados: $destinoPacotes"
}

# O iniciar-kit.cmd chama o installer.ps1 da raiz do kit, por isso ele fica um
# nivel acima da pasta scripts no projeto e na raiz no kit distribuido.
$cmdKit = Join-Path $Destino 'iniciar-kit.cmd'
(Get-Content -LiteralPath $cmdKit -Raw) -replace 'cd /d "%~dp0\.\."', 'cd /d "%~dp0"' |
    Set-Content -LiteralPath $cmdKit -Encoding ASCII

Get-ChildItem -LiteralPath $Destino -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
    Unblock-File -LiteralPath $_.FullName -ErrorAction SilentlyContinue
}

$zip = Join-Path (Split-Path -Parent $Destino) ((Split-Path -Leaf $Destino) + '.zip')
if (Test-Path -LiteralPath $zip) {
    Remove-Item -LiteralPath $zip -Force
}
Compress-Archive -Path (Join-Path $Destino '*') -DestinationPath $zip -Force

Write-Host ""
Write-Host "Kit pronto em : $Destino"
Write-Host "ZIP do cliente: $zip"
Write-Host "No cliente: extraia o ZIP e clique duas vezes em iniciar-kit.cmd (aceite o UAC)."
