<#
    iniciar-vm-dvd.ps1

    Reinicia a VM e envia teclas automaticamente durante o boot, resolvendo o
    "Press any key to boot from CD or DVD" do instalador do Windows.

    Por que isso e necessario: em VMs de Geracao 2, o bootloader do Windows na
    ISO espera uma tecla por poucos segundos. Sem ela, ele aborta de proposito
    ("The boot loader failed") e o UEFI passa para o proximo dispositivo.
    O Hyper-V expoe o teclado sintetico da VM na classe WMI Msvm_Keyboard, o que
    permite pressionar a tecla no instante certo por script.

    IMPORTANTE: precisa ser executado como Administrador.

    Exemplo:
        .\iniciar-vm-dvd.ps1 -Nome 'VM-Win11'
#>

# CUIDADO com a quantidade de teclas: enquanto o WinPE carrega, as teclas enviadas
# ficam no buffer e sao entregues de uma vez quando o assistente aparece, clicando
# nos botoes padrao de varias telas seguidas (inclusive a escolha da edicao do
# Windows). Por isso o padrao e apenas 2 teclas na janela do firmware.
[CmdletBinding()]
param(
    [string] $Nome            = 'VM-Win11',
    [int]    $Teclas          = 2,
    [int]    $AtrasoInicialMs = 2000,
    [int]    $IntervaloMs     = 2000
)

$ErrorActionPreference = 'Stop'
$namespace = 'root\virtualization\v2'

$vmWmi = Get-WmiObject -Namespace $namespace -Class Msvm_ComputerSystem -Filter "ElementName='$Nome'"
if (-not $vmWmi) { throw "VM '$Nome' nao encontrada." }

$teclado = $vmWmi.GetRelated('Msvm_Keyboard') | Select-Object -First 1
if (-not $teclado) {
    throw "Teclado sintetico (Msvm_Keyboard) indisponivel. Sera necessario pressionar a tecla manualmente na janela do vmconnect."
}

Write-Host ">> Desligando a VM para um boot limpo" -ForegroundColor Cyan
Stop-VM -Name $Nome -TurnOff -Force -ErrorAction SilentlyContinue
do { Start-Sleep -Milliseconds 500 } while ((Get-VM -Name $Nome).State -ne 'Off')

Write-Host ">> Ligando a VM" -ForegroundColor Cyan
Start-VM -Name $Nome

# O teclado precisa ser relido: a instancia anterior era da sessao antiga da VM.
Start-Sleep -Seconds 1
$vmWmi   = Get-WmiObject -Namespace $namespace -Class Msvm_ComputerSystem -Filter "ElementName='$Nome'"
$teclado = $vmWmi.GetRelated('Msvm_Keyboard') | Select-Object -First 1

$vkEspaco = 0x20
Write-Host ">> Aguardando $AtrasoInicialMs ms e enviando ESPACO $Teclas vez(es)" -ForegroundColor Cyan
Start-Sleep -Milliseconds $AtrasoInicialMs

for ($i = 1; $i -le $Teclas; $i++) {
    try { $teclado.TypeKey($vkEspaco) | Out-Null } catch { }
    if ($i -lt $Teclas) { Start-Sleep -Milliseconds $IntervaloMs }
}

Write-Host ">> Teclas enviadas. Estado atual:" -ForegroundColor Green
Get-VM -Name $Nome | Format-List Name, State, Uptime
