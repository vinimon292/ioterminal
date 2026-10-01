#requires -Version 5.1
<#
.SYNOPSIS
    Envia o ioterminal-kit.zip para a VM de teste e traz os logs de volta.
.DESCRIPTION
    Usa PowerShell Direct (sessao pelo barramento do Hyper-V), que funciona sem rede
    na VM e permite trafego nos dois sentidos: manda o kit e busca o log do instalador.
    Se a sessao direta nao estiver disponivel, cai para Copy-VMFile, que so envia.

    Antes de enviar, chama o atualizar-zip.ps1 para garantir que o ZIP corresponde
    ao estado atual do projeto.
.PARAMETER Nome
    Nome da VM no Hyper-V.
.PARAMETER DestinoNaVM
    Pasta dentro da VM que recebe o kit.
.PARAMETER Extrair
    Extrai o ZIP dentro da VM e desbloqueia os arquivos.
.PARAMETER TrazerLog
    Copia os logs do instalador da VM para a pasta de logs do host.
.EXAMPLE
    .\scripts\enviar-para-vm.ps1 -Extrair
.EXAMPLE
    .\scripts\enviar-para-vm.ps1 -TrazerLog
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$Nome = 'Teste IOTerminal',

    [Parameter(Mandatory = $false)]
    [string]$DestinoNaVM = 'C:\ioterminal-kit',

    [Parameter(Mandatory = $false)]
    [switch]$Extrair,

    [Parameter(Mandatory = $false)]
    [switch]$TrazerLog,

    [Parameter(Mandatory = $false)]
    [string]$PastaLogHost = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$raiz = Split-Path -Parent $PSScriptRoot
$zip = Join-Path $raiz 'ioterminal-kit.zip'
$logDaVM = 'C:\ProgramData\OficinaBinaria\ioterminal-setup'

function Escrever-Etapa {
    param([Parameter(Mandatory = $true)][string]$Texto)
    Write-Host ""
    Write-Host ">> $Texto" -ForegroundColor Cyan
}

# --- 1. Garantir que o ZIP esta atualizado -----------------------------------
Escrever-Etapa 'Conferindo o kit'
& (Join-Path $PSScriptRoot 'atualizar-zip.ps1')

if (-not (Test-Path -LiteralPath $zip)) {
    throw "ZIP nao encontrado: $zip. Rode scripts\atualizar-zip.ps1 -Forcar."
}

$info = Get-Item -LiteralPath $zip
Write-Host ("   {0} | {1} MB | {2}" -f $info.Name, [math]::Round($info.Length / 1MB, 2), $info.LastWriteTime)

# --- 2. Conferir a VM --------------------------------------------------------
Escrever-Etapa "Conferindo a VM '$Nome'"

$vm = Get-VM -Name $Nome -ErrorAction SilentlyContinue
if (-not $vm) {
    throw "VM '$Nome' nao existe. Use -Nome para indicar outra, ou crie com vm\criar-vm-hyperv.ps1."
}

if ($vm.State -ne 'Running') {
    throw "VM '$Nome' esta em '$($vm.State)'. Ligue com: Start-VM -Name '$Nome'"
}

Write-Host "   Estado: $($vm.State)"

# --- 3. Sessao PowerShell Direct ---------------------------------------------
Escrever-Etapa 'Abrindo sessao com a VM (PowerShell Direct)'
Write-Host '   Informe uma conta administrador DA VM (ex.: VM\usuario ou .\usuario)'

$credencial = Get-Credential -Message "Conta administrador da VM '$Nome'"
$sessao = $null

try {
    $sessao = New-PSSession -VMName $Nome -Credential $credencial -ErrorAction Stop
    Write-Host '   Sessao estabelecida.' -ForegroundColor Green
}
catch {
    Write-Warning "PowerShell Direct falhou: $($_.Exception.Message)"
    Write-Host '   Tentando Copy-VMFile (somente envio, sem retorno de log)...' -ForegroundColor Yellow

    Copy-VMFile -Name $Nome `
                -SourcePath $zip `
                -DestinationPath (Join-Path $DestinoNaVM (Split-Path -Leaf $zip)) `
                -FileSource Host `
                -CreateFullPath `
                -Force

    Write-Host ""
    Write-Host "OK: kit copiado para $DestinoNaVM dentro da VM." -ForegroundColor Green
    Write-Host 'Extraia o ZIP na VM e rode o iniciar-kit.cmd como administrador.'
    exit 0
}

try {
    # --- 4. Enviar o ZIP -----------------------------------------------------
    Escrever-Etapa "Enviando o kit para $DestinoNaVM"

    Invoke-Command -Session $sessao -ScriptBlock {
        param($pasta)
        if (-not (Test-Path -LiteralPath $pasta)) {
            New-Item -ItemType Directory -Path $pasta -Force | Out-Null
        }
    } -ArgumentList $DestinoNaVM

    Copy-Item -LiteralPath $zip -Destination $DestinoNaVM -ToSession $sessao -Force
    Write-Host '   Kit enviado.' -ForegroundColor Green

    # --- 5. Extrair dentro da VM --------------------------------------------
    if ($Extrair) {
        Escrever-Etapa 'Extraindo o kit dentro da VM'

        $resultado = Invoke-Command -Session $sessao -ScriptBlock {
            param($pasta, $nomeZip)

            $arquivo = Join-Path $pasta $nomeZip
            Expand-Archive -LiteralPath $arquivo -DestinationPath $pasta -Force

            # Arquivo vindo de fora costuma ficar marcado como baixado da internet.
            Get-ChildItem -LiteralPath $pasta -Recurse -File -ErrorAction SilentlyContinue |
                ForEach-Object { Unblock-File -LiteralPath $_.FullName -ErrorAction SilentlyContinue }

            [PSCustomObject]@{
                TemInstalador = Test-Path -LiteralPath (Join-Path $pasta 'installer.ps1')
                TemAtalho     = Test-Path -LiteralPath (Join-Path $pasta 'iniciar-kit.cmd')
                TemExtrator   = Test-Path -LiteralPath (Join-Path $pasta 'ferramentas\7z.exe')
                TemPacotes    = Test-Path -LiteralPath (Join-Path $pasta 'IOTERMINAL')
            }
        } -ArgumentList $DestinoNaVM, (Split-Path -Leaf $zip)

        Write-Host "   installer.ps1    : $($resultado.TemInstalador)"
        Write-Host "   iniciar-kit.cmd  : $($resultado.TemAtalho)"
        Write-Host "   ferramentas\7z   : $($resultado.TemExtrator)"
        Write-Host "   IOTERMINAL       : $($resultado.TemPacotes)"
    }

    # --- 6. Trazer os logs de volta -----------------------------------------
    if ($TrazerLog) {
        Escrever-Etapa 'Buscando logs do instalador na VM'

        $arquivos = Invoke-Command -Session $sessao -ScriptBlock {
            param($pastaLog)
            if (-not (Test-Path -LiteralPath $pastaLog)) { return @() }
            @(Get-ChildItem -LiteralPath $pastaLog -Filter '*.log' -File |
                Sort-Object LastWriteTime -Descending | Select-Object -First 5 -ExpandProperty FullName)
        } -ArgumentList $logDaVM

        if (@($arquivos).Count -eq 0) {
            Write-Warning "Nenhum log em $logDaVM (o instalador ainda nao rodou na VM)."
        }
        else {
            $destinoLog = if ($PastaLogHost) { $PastaLogHost } else { Join-Path $raiz 'logs-vm' }
            if (-not (Test-Path -LiteralPath $destinoLog)) {
                New-Item -ItemType Directory -Path $destinoLog -Force | Out-Null
            }

            foreach ($arquivo in $arquivos) {
                Copy-Item -LiteralPath $arquivo -Destination $destinoLog -FromSession $sessao -Force
                Write-Host "   $(Split-Path -Leaf $arquivo)"
            }

            Write-Host "   Logs em: $destinoLog" -ForegroundColor Green
        }
    }
}
finally {
    if ($sessao) { Remove-PSSession -Session $sessao -ErrorAction SilentlyContinue }
}

Write-Host ""
Write-Host 'Concluido.' -ForegroundColor Green
if (-not $Extrair) {
    Write-Host "Na VM: extraia $DestinoNaVM\$(Split-Path -Leaf $zip) e rode o iniciar-kit.cmd como administrador."
}
else {
    Write-Host "Na VM: abra $DestinoNaVM e rode o iniciar-kit.cmd como administrador."
}
Write-Host "Depois do teste: .\scripts\enviar-para-vm.ps1 -TrazerLog  (busca o log do instalador)"
