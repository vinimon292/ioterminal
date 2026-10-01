<#
    vm-interno-habilitar-rdp.ps1

    RODAR DENTRO DA MAQUINA VIRTUAL, como Administrador.

    Habilita o servidor de area de trabalho remota, que e o requisito para a
    sessao aprimorada do Hyper-V. Com ela, a resolucao da VM passa a acompanhar
    o tamanho da janela e a escala de DPI do host e repassada ao convidado,
    resolvendo tela pequena em monitor 4K.

    Tambem informa a edicao do Windows instalada, porque a edicao Home nao
    possui esse servidor e portanto nao suporta sessao aprimorada.
#>

$ErrorActionPreference = 'Stop'

$identidade = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $identidade.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Abra o PowerShell como Administrador e rode novamente.' -ForegroundColor Red
    Read-Host 'ENTER para fechar'
    exit 1
}

$so  = Get-CimInstance Win32_OperatingSystem
$sku = $so.OperatingSystemSKU

Write-Host ''
Write-Host "Edicao instalada : $($so.Caption)" -ForegroundColor Cyan
Write-Host "SKU              : $sku" -ForegroundColor Cyan
Write-Host "Build            : $($so.BuildNumber)" -ForegroundColor Cyan
Write-Host ''

# SKUs das edicoes Home / Single Language, que nao tem servidor de RDP.
$skusSemRdp = @(98, 100, 101, 121, 122)

if ($sku -in $skusSemRdp) {
    Write-Host 'Esta e uma edicao Home: nao ha servidor de area de trabalho remota,' -ForegroundColor Yellow
    Write-Host 'portanto a sessao aprimorada nao esta disponivel.' -ForegroundColor Yellow
    Write-Host ''
    Write-Host 'Alternativa: Configuracoes > Sistema > Tela' -ForegroundColor Yellow
    Write-Host '  - Resolucao : 1920 x 1200' -ForegroundColor Yellow
    Write-Host '  - Escala    : 150%' -ForegroundColor Yellow
    Read-Host 'ENTER para fechar'
    exit 0
}

$chaveTS = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
$antes = (Get-ItemProperty $chaveTS -Name fDenyTSConnections -ErrorAction SilentlyContinue).fDenyTSConnections
Write-Host "Area de trabalho remota antes: $(if ($antes -eq 0) { 'ligada' } else { 'desligada' })"

Set-ItemProperty -Path $chaveTS -Name fDenyTSConnections -Value 0

# O grupo de regras do firewall e referenciado pelo ID e nao pelo nome, porque o
# nome vem traduzido conforme o idioma do Windows.
Enable-NetFirewallRule -Group '@FirewallAPI.dll,-28752' -ErrorAction SilentlyContinue

Set-Service -Name TermService -StartupType Automatic
Start-Service -Name TermService -ErrorAction SilentlyContinue

$servico = Get-Service TermService

Write-Host ''
Write-Host 'Area de trabalho remota HABILITADA.' -ForegroundColor Green
Write-Host "Servico TermService: $($servico.Status)" -ForegroundColor Green
Write-Host ''
Write-Host 'Agora, no computador fisico (host):' -ForegroundColor Cyan
Write-Host '  1. Feche esta janela de conexao da VM'
Write-Host '  2. Abra o Gerenciador do Hyper-V e conecte na VM novamente'
Write-Host '  3. Escolha o tamanho de tela na barra que aparecer, ou marque Tela Inteira'
Write-Host ''
Write-Host 'E dentro da VM, para texto e icones maiores:' -ForegroundColor Cyan
Write-Host '  Configuracoes > Sistema > Tela > Escala: 150%'
Write-Host ''
Read-Host 'ENTER para fechar'
