<#
    criar-vm-hyperv.ps1

    Cria uma maquina virtual Hyper-V de Geracao 2 pronta para instalar o Windows 11
    (Secure Boot + TPM virtual, exigencias do instalador do Windows 11).

    IMPORTANTE: precisa ser executado em um PowerShell como Administrador.

    Exemplos:
        .\criar-vm-hyperv.ps1
        .\criar-vm-hyperv.ps1 -Iso "C:\Users\bina1\Downloads\Win11_25H2_x64.iso"
        .\criar-vm-hyperv.ps1 -Nome "VM-Teste" -MemoriaBytes 4GB -Processadores 2 -DiscoBytes 60GB
#>

[CmdletBinding()]
param(
    [string] $Nome            = 'VM-Win11',
    [string] $Pasta           = 'F:\Hyper-V',
    [int64]  $MemoriaBytes    = 8GB,
    [int]    $Processadores   = 4,
    [int64]  $DiscoBytes      = 80GB,
    [string] $Iso             = '',
    [string] $AdaptadorFisico = 'Ethernet',
    [string] $SwitchNome      = 'vSwitch-Externo'
)

$ErrorActionPreference = 'Stop'

function Escrever-Etapa([string] $Texto) {
    Write-Host ""
    Write-Host ">> $Texto" -ForegroundColor Cyan
}

# --- 1. Validacoes de ambiente -------------------------------------------------
$identidade = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $identidade.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Execute este script em um PowerShell aberto como Administrador."
}

if (-not (Get-Module -ListAvailable -Name Hyper-V)) {
    throw "Modulo Hyper-V nao encontrado. Habilite o Hyper-V nos recursos do Windows."
}

$raiz = (Split-Path -Path $Pasta -Qualifier) + '\'
if (-not (Test-Path $raiz)) {
    throw "A unidade $raiz nao existe. Informe outro caminho em -Pasta."
}

if (Get-VM -Name $Nome -ErrorAction SilentlyContinue) {
    throw "Ja existe uma VM chamada '$Nome'. Escolha outro nome em -Nome."
}

if ($Iso -and -not (Test-Path $Iso)) {
    throw "Arquivo ISO nao encontrado: $Iso"
}

# --- 2. Pastas ----------------------------------------------------------------
Escrever-Etapa "Preparando pastas em $Pasta"
$pastaVM  = Join-Path $Pasta $Nome
$caminhoVhd = Join-Path $pastaVM "$Nome.vhdx"
New-Item -Path $pastaVM -ItemType Directory -Force | Out-Null
Write-Host "   Pasta da VM: $pastaVM"

# --- 3. Switch virtual --------------------------------------------------------
Escrever-Etapa "Verificando switch virtual de rede"
$switch = Get-VMSwitch -Name $SwitchNome -ErrorAction SilentlyContinue

if (-not $switch) {
    $switch = Get-VMSwitch | Where-Object SwitchType -eq 'External' | Select-Object -First 1
}

if ($switch) {
    Write-Host "   Usando switch existente: $($switch.Name) ($($switch.SwitchType))"
}
else {
    $adaptador = Get-NetAdapter -Name $AdaptadorFisico -ErrorAction SilentlyContinue
    if (-not $adaptador -or $adaptador.Status -ne 'Up') {
        throw "Adaptador fisico '$AdaptadorFisico' nao encontrado ou inativo. Rode Get-NetAdapter e informe o nome correto em -AdaptadorFisico."
    }

    Write-Host "   Nenhum switch externo encontrado." -ForegroundColor Yellow
    Write-Host "   Sera criado o switch '$SwitchNome' sobre o adaptador '$AdaptadorFisico'." -ForegroundColor Yellow
    Write-Host "   ATENCAO: a rede do computador cai por alguns segundos durante a criacao." -ForegroundColor Yellow
    $resposta = Read-Host "   Continuar? (S/N)"
    if ($resposta -notmatch '^[SsYy]') {
        throw "Criacao cancelada pelo usuario."
    }

    $switch = New-VMSwitch -Name $SwitchNome -NetAdapterName $AdaptadorFisico -AllowManagementOS $true
    Write-Host "   Switch externo criado: $($switch.Name)" -ForegroundColor Green
}

# --- 4. Disco virtual ---------------------------------------------------------
Escrever-Etapa "Criando disco virtual de $([math]::Round($DiscoBytes/1GB)) GB (expansao dinamica)"
New-VHD -Path $caminhoVhd -SizeBytes $DiscoBytes -Dynamic | Out-Null
Write-Host "   Disco: $caminhoVhd"

# --- 5. Maquina virtual -------------------------------------------------------
Escrever-Etapa "Criando a maquina virtual '$Nome' (Geracao 2)"
$vm = New-VM -Name $Nome `
             -Generation 2 `
             -MemoryStartupBytes $MemoriaBytes `
             -VHDPath $caminhoVhd `
             -SwitchName $switch.Name `
             -Path $Pasta

# --- 6. CPU, memoria e comportamento ------------------------------------------
Escrever-Etapa "Ajustando CPU, memoria e opcoes gerais"
Set-VMProcessor -VMName $Nome -Count $Processadores
Set-VMMemory   -VMName $Nome -DynamicMemoryEnabled $true `
                             -StartupBytes  $MemoriaBytes `
                             -MinimumBytes  2GB `
                             -MaximumBytes  ([int64]($MemoriaBytes * 2))

# Checkpoints automaticos consomem espaco em disco a cada inicializacao.
Set-VM -VMName $Nome -CheckpointType Standard -AutomaticCheckpointsEnabled $false
Set-VM -VMName $Nome -AutomaticStartAction Nothing -AutomaticStopAction ShutDown

# Permite copiar arquivos do host para a VM (Copy-VMFile).
# O nome do componente e traduzido conforme o idioma do Windows, por isso filtramos pelo ID fixo.
$idGuestService = '6C09BB55-D683-4DA0-8931-C9BF705F6480'
$servicoConvidado = Get-VMIntegrationService -VMName $Nome |
                        Where-Object { $_.Id -like "*$idGuestService*" }
if ($servicoConvidado) {
    Enable-VMIntegrationService -VMIntegrationService $servicoConvidado
}
else {
    Write-Host "   Aviso: servico de copia de arquivos nao encontrado, seguindo sem ele." -ForegroundColor Yellow
}
Write-Host "   $Processadores vCPUs, memoria dinamica iniciando em $([math]::Round($MemoriaBytes/1GB)) GB"

# --- 7. Secure Boot e TPM (obrigatorios para Windows 11) ----------------------
Escrever-Etapa "Habilitando Secure Boot e TPM virtual"
Set-VMFirmware -VMName $Nome -EnableSecureBoot On -SecureBootTemplate 'MicrosoftWindows'
Set-VMKeyProtector -VMName $Nome -NewLocalKeyProtector
Enable-VMTPM -VMName $Nome
Write-Host "   Secure Boot: On | TPM virtual: habilitado"

# --- 8. ISO de instalacao -----------------------------------------------------
if ($Iso) {
    Escrever-Etapa "Anexando ISO e definindo ordem de boot"
    Add-VMDvdDrive -VMName $Nome -Path $Iso
    $dvd = Get-VMDvdDrive -VMName $Nome
    Set-VMFirmware -VMName $Nome -FirstBootDevice $dvd
    Write-Host "   ISO: $Iso"
    Write-Host "   Boot pelo DVD virtual configurado"
}
else {
    Escrever-Etapa "Nenhuma ISO informada"
    Write-Host "   Depois de baixar a ISO, rode:" -ForegroundColor Yellow
    Write-Host "     Add-VMDvdDrive -VMName '$Nome' -Path 'C:\caminho\Win11.iso'" -ForegroundColor Yellow
    Write-Host "     Set-VMFirmware -VMName '$Nome' -FirstBootDevice (Get-VMDvdDrive -VMName '$Nome')" -ForegroundColor Yellow
}

# --- 9. Resumo ----------------------------------------------------------------
Escrever-Etapa "VM criada com sucesso"
Get-VM -Name $Nome | Format-List Name, State, Generation, ProcessorCount, MemoryStartup, MemoryMinimum, MemoryMaximum, Path
Write-Host "Para iniciar e conectar:" -ForegroundColor Green
Write-Host "   Start-VM -Name '$Nome'; vmconnect.exe localhost '$Nome'" -ForegroundColor Green
