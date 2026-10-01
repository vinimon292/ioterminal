<#
    configurar-tela-vm.ps1

    Prepara a VM para sessao aprimorada (resolucao dinamica, area de transferencia
    compartilhada e escala de DPI correta em monitores 4K) e ajusta a resolucao
    de video maxima.

    Como funciona: a sessao aprimorada do Hyper-V e uma conexao RDP transportada
    pelo VMBus. Por isso ela exige o servidor de area de trabalho remota dentro do
    sistema convidado, presente no Windows Pro/Enterprise e ausente no Home.
    Sem ela, o vmconnect usa "sessao basica", onde a resolucao fica fixa e nao
    acompanha o tamanho da janela.

    A senha da VM e pedida em caixa de dialogo do Windows, nunca em texto.

    IMPORTANTE: precisa ser executado como Administrador.

    Exemplo:
        .\configurar-tela-vm.ps1 -Nome 'VM-Win11'
#>

[CmdletBinding()]
param(
    [string] $Nome       = 'VM-Win11',
    [int]    $Largura    = 1920,
    [int]    $Altura     = 1200,
    [string] $Relatorio  = "$env:USERPROFILE\relatorio-tela-vm.txt"
)

$ErrorActionPreference = 'Stop'
$linhas = @()

function Registrar([string] $Texto) {
    Write-Host $Texto
    $script:linhas += $Texto
}

$vm = Get-VM -Name $Nome
if ($vm.State -ne 'Running') { throw "A VM '$Nome' precisa estar ligada. Estado: $($vm.State)" }

# --- 1. Sessao aprimorada no host --------------------------------------------
Registrar '=== HOST ==='
$vmHost = Get-VMHost
Registrar "Sessao aprimorada no host (antes): $($vmHost.EnableEnhancedSessionMode)"
if (-not $vmHost.EnableEnhancedSessionMode) {
    Set-VMHost -EnableEnhancedSessionMode $true
    Registrar 'Sessao aprimorada HABILITADA no host.'
}

# --- 2. Resolucao maxima do video virtual ------------------------------------
$video = Get-VMVideo -VMName $Nome
Registrar "Video da VM (antes): $($video.HorizontalResolution) x $($video.VerticalResolution) / tipo $($video.ResolutionType)"
if ($video.HorizontalResolution -lt $Largura -or $video.VerticalResolution -lt $Altura) {
    Set-VMVideo -VMName $Nome -ResolutionType Maximum -HorizontalResolution $Largura -VerticalResolution $Altura
    Registrar "Video ajustado para o maximo de $Largura x $Altura (vale apos desligar e ligar a VM)."
}

# --- 3. Dentro da VM ----------------------------------------------------------
$credencial = Get-Credential -Message "Usuario e senha da conta administradora DENTRO da VM '$Nome'"

$resultado = Invoke-Command -VMName $Nome -Credential $credencial -ScriptBlock {

    $so = Get-CimInstance Win32_OperatingSystem
    $chaveTS = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'

    # Edicao Home nao possui o servidor de area de trabalho remota, requisito da
    # sessao aprimorada. Detectamos pela SKU do sistema.
    #  48 = Professional, 101 = Home, 4 = Enterprise, 27/48 variantes
    $sku = (Get-CimInstance Win32_OperatingSystem).OperatingSystemSKU
    $temRdpHost = $sku -notin @(98, 100, 101, 121, 122)

    $antes = (Get-ItemProperty $chaveTS -Name fDenyTSConnections -ErrorAction SilentlyContinue).fDenyTSConnections
    $habilitou = $false

    if ($temRdpHost) {
        Set-ItemProperty -Path $chaveTS -Name fDenyTSConnections -Value 0
        # O grupo de regras de firewall e identificado pelo ID, nao pelo nome,
        # porque o nome vem traduzido conforme o idioma do Windows.
        Enable-NetFirewallRule -Group '@FirewallAPI.dll,-28752' -ErrorAction SilentlyContinue
        Set-Service -Name TermService -StartupType Automatic -ErrorAction SilentlyContinue
        Start-Service -Name TermService -ErrorAction SilentlyContinue
        $habilitou = $true
    }

    $tela = Get-CimInstance Win32_VideoController | Select-Object -First 1

    [PSCustomObject]@{
        Edicao          = $so.Caption
        Sku             = $sku
        Build           = $so.BuildNumber
        TemRdpHost      = $temRdpHost
        RdpAntes        = $antes
        RdpHabilitado   = $habilitou
        ServicoRdp      = (Get-Service TermService -ErrorAction SilentlyContinue).Status
        ResolucaoAtual  = "$($tela.CurrentHorizontalResolution) x $($tela.CurrentVerticalResolution)"
        Usuario         = "$env:USERDOMAIN\$env:USERNAME"
    }
}

Registrar ''
Registrar '=== DENTRO DA VM ==='
Registrar "Edicao          : $($resultado.Edicao) (SKU $($resultado.Sku))"
Registrar "Build           : $($resultado.Build)"
Registrar "Usuario         : $($resultado.Usuario)"
Registrar "Resolucao atual : $($resultado.ResolucaoAtual)"
Registrar "Suporta RDP host: $($resultado.TemRdpHost)"
Registrar "RDP habilitado  : $($resultado.RdpHabilitado)  (servico: $($resultado.ServicoRdp))"

Registrar ''
if ($resultado.TemRdpHost) {
    Registrar 'RESULTADO: sessao aprimorada disponivel.'
    Registrar 'Feche a janela do vmconnect e conecte novamente; use o botao'
    Registrar '"Exibir > Sessao Aprimorada" ou o icone de tela na barra de ferramentas.'
}
else {
    Registrar 'RESULTADO: edicao Home detectada, sessao aprimorada NAO disponivel.'
    Registrar 'Alternativa: ajustar resolucao e escala dentro da VM em'
    Registrar 'Configuracoes > Sistema > Tela.'
}

$linhas | Out-File -FilePath $Relatorio -Encoding UTF8
Write-Host ""
Write-Host "Relatorio salvo em: $Relatorio" -ForegroundColor Green
