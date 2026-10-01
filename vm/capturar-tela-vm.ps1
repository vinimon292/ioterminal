<#
    capturar-tela-vm.ps1

    Captura a tela atual de uma maquina virtual Hyper-V e salva como PNG.
    Util para diagnosticar telas de boot, instaladores e travamentos sem
    precisar olhar a janela do vmconnect.

    Funciona pelo metodo GetVirtualSystemThumbnailImage do servico de
    gerenciamento do Hyper-V (WMI), que devolve os pixels crus da tela da VM
    no formato RGB565.

    IMPORTANTE: precisa ser executado como Administrador.

    Exemplo:
        .\capturar-tela-vm.ps1 -Nome 'VM-Win11' -Saida 'C:\temp\tela.png'
#>

[CmdletBinding()]
param(
    [string] $Nome  = 'VM-Win11',
    [string] $Saida = "$env:TEMP\tela-vm.png"
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$namespace = 'root\virtualization\v2'

$vm = Get-WmiObject -Namespace $namespace -Class Msvm_ComputerSystem -Filter "ElementName='$Nome'"
if (-not $vm) { throw "VM '$Nome' nao encontrada." }

# A configuracao "Realized" e a que esta em uso pela VM ligada.
$config = $vm.GetRelated('Msvm_VirtualSystemSettingData') |
              Where-Object { $_.VirtualSystemType -eq 'Microsoft:Hyper-V:System:Realized' }

# Resolucao real da tela da VM; se a VM estiver sem video ativo usamos um padrao.
$video = $vm.GetRelated('Msvm_VideoHead') | Select-Object -First 1
$resolucoes = @()
if ($video -and $video.CurrentHorizontalResolution) {
    $resolucoes += ,@([int]$video.CurrentHorizontalResolution, [int]$video.CurrentVerticalResolution)
}
# O metodo tem limite de tamanho, por isso as alternativas menores.
$resolucoes += ,@(1024, 768)
$resolucoes += ,@(800, 600)
$resolucoes += ,@(640, 480)

$servico = Get-WmiObject -Namespace $namespace -Class Msvm_VirtualSystemManagementService

$bytes = $null
foreach ($res in $resolucoes) {
    $largura = $res[0]
    $altura  = $res[1]
    try {
        $params = $servico.GetMethodParameters('GetVirtualSystemThumbnailImage')
        $params.WidthPixels   = $largura
        $params.HeightPixels  = $altura
        $params.TargetSystem  = $config.__PATH
        $retorno = $servico.InvokeMethod('GetVirtualSystemThumbnailImage', $params, $null)

        if ($retorno.ReturnValue -eq 0 -and $retorno.ImageData) {
            $bytes = $retorno.ImageData
            break
        }
    }
    catch {
        # Resolucao rejeitada, tenta a proxima.
    }
}

if (-not $bytes) { throw "Nao foi possivel capturar a tela da VM '$Nome'." }

# RGB565 = 2 bytes por pixel.
$bitmap = New-Object System.Drawing.Bitmap($largura, $altura,
              [System.Drawing.Imaging.PixelFormat]::Format16bppRgb565)
$area = New-Object System.Drawing.Rectangle(0, 0, $largura, $altura)
$dados = $bitmap.LockBits($area, [System.Drawing.Imaging.ImageLockMode]::WriteOnly, $bitmap.PixelFormat)
try {
    # Copia linha por linha porque o Stride do bitmap pode ser maior que largura*2.
    for ($y = 0; $y -lt $altura; $y++) {
        $destino = [IntPtr]::Add($dados.Scan0, $y * $dados.Stride)
        [System.Runtime.InteropServices.Marshal]::Copy($bytes, $y * $largura * 2, $destino, $largura * 2)
    }
}
finally {
    $bitmap.UnlockBits($dados)
}

$bitmap.Save($Saida, [System.Drawing.Imaging.ImageFormat]::Png)
$bitmap.Dispose()

Write-Output "Tela capturada: $Saida ($largura x $altura)"
