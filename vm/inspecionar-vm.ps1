<#
    inspecionar-vm.ps1

    Gera um inventario do sistema dentro de uma VM Hyper-V e salva em arquivo no host.

    Usa PowerShell Direct (Invoke-Command -VMName), que fala com o sistema convidado
    pelo barramento VMBus do Hyper-V, sem precisar de rede, IP ou WinRM configurado.
    Requisito: o convidado precisa ser Windows 10/11 ou Server 2016+ e estar ligado.

    A senha e pedida em caixa de dialogo do Windows, nunca em texto no script.

    IMPORTANTE: precisa ser executado como Administrador.

    Exemplo:
        .\inspecionar-vm.ps1 -Nome 'VM-Win11' -Saida 'C:\temp\inventario.txt'
#>

[CmdletBinding()]
param(
    [string] $Nome  = 'VM-Win11',
    [string] $Saida = "$env:USERPROFILE\inventario-vm.txt"
)

$ErrorActionPreference = 'Stop'

$vm = Get-VM -Name $Nome
if ($vm.State -ne 'Running') { throw "A VM '$Nome' precisa estar ligada. Estado atual: $($vm.State)" }

$credencial = Get-Credential -Message "Informe usuario e senha da conta administradora DENTRO da VM '$Nome'"

$relatorio = Invoke-Command -VMName $Nome -Credential $credencial -ScriptBlock {

    $so = Get-CimInstance Win32_OperatingSystem
    $lic = Get-CimInstance SoftwareLicensingProduct -Filter "PartialProductKey IS NOT NULL AND Name LIKE 'Windows%'" |
               Select-Object -First 1

    [PSCustomObject]@{
        Edicao          = $so.Caption
        Versao          = "$($so.Version) / build $($so.BuildNumber)"
        Ativacao        = if ($lic) { $lic.LicenseStatus } else { 'desconhecida' }
        MemoriaLivreMB  = [math]::Round($so.FreePhysicalMemory / 1024)
        DiscoLivreGB    = [math]::Round((Get-PSDrive C).Free / 1GB, 1)

        # Apps da Store instalados para o usuario atual.
        AppsUsuario     = Get-AppxPackage |
                              Where-Object { -not $_.IsFramework -and -not $_.NonRemovable } |
                              Select-Object -ExpandProperty Name | Sort-Object

        # Apps provisionados: os que voltam a instalar em cada novo usuario criado.
        AppsProvisionados = (Get-AppxProvisionedPackage -Online).DisplayName | Sort-Object

        # Programas classicos instalados (registro de desinstalacao, 64 e 32 bits).
        ProgramasDesktop = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                                            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' `
                                            -ErrorAction SilentlyContinue |
                              Where-Object { $_.DisplayName } |
                              Select-Object -ExpandProperty DisplayName |
                              Sort-Object -Unique

        # Servicos automaticos que costumam ser peso morto em maquina de desenvolvimento.
        ServicosAuto    = Get-Service |
                              Where-Object { $_.StartType -eq 'Automatic' } |
                              Select-Object -ExpandProperty Name | Sort-Object
    }
}

$texto = @()
$texto += "=== SISTEMA ==="
$texto += "Edicao         : $($relatorio.Edicao)"
$texto += "Versao         : $($relatorio.Versao)"
$texto += "Ativacao       : $($relatorio.Ativacao)  (1 = ativado)"
$texto += "Memoria livre  : $($relatorio.MemoriaLivreMB) MB"
$texto += "Disco C: livre : $($relatorio.DiscoLivreGB) GB"
$texto += ""
$texto += "=== APPS DA STORE - USUARIO ATUAL ($($relatorio.AppsUsuario.Count)) ==="
$texto += $relatorio.AppsUsuario
$texto += ""
$texto += "=== APPS PROVISIONADOS - VOLTAM EM NOVO USUARIO ($($relatorio.AppsProvisionados.Count)) ==="
$texto += $relatorio.AppsProvisionados
$texto += ""
$texto += "=== PROGRAMAS DESKTOP ($($relatorio.ProgramasDesktop.Count)) ==="
$texto += $relatorio.ProgramasDesktop
$texto += ""
$texto += "=== SERVICOS EM INICIO AUTOMATICO ($($relatorio.ServicosAuto.Count)) ==="
$texto += ($relatorio.ServicosAuto -join ', ')

$texto | Out-File -FilePath $Saida -Encoding UTF8
Write-Output "Inventario salvo em: $Saida"
