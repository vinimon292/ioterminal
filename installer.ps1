#requires -Version 5.1
<#
.SYNOPSIS
    Instalador automatizado do IOTerminal (IOT Multitool).
.DESCRIPTION
    Prepara a estacao em ordem deterministica:
      1. driver FTDI (CDM 2.08.24 no Windows 10 antigo; CDM 2.12.36.20 WHQL no Windows 11)
      2. IOT Multitool V50B (aplicacao portatil, extraida para a pasta de instalacao)
      3. biblioteca D2XX (ftd2xx.dll na pasta do IOT e em SysWOW64)
      4. licenca IDMONACT (copiada para dentro da pasta do IOT Multitool)

    O iniciar-kit.cmd chama este script com -Reinstall: apaga a pasta do IOT
    (se existir) e instala de novo. O driver FTDI publicado e preservado.

    Toda alteracao do sistema e precedida de deteccao (detect) e seguida de
    validacao (validate), com estado gravado para permitir rollback.
.NOTES
    Documentacao : README.md, docs/OPERACAO.md, docs/MANIFESTO.md, docs/CODIGOS-SAIDA.md
    Referencia   : projeto PCMFlash (mesmo contrato de manifesto e codigos de saida)
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ManifestPath = '',

    [Parameter(Mandatory = $false)]
    [string]$PackageDir = '',

    [Parameter(Mandatory = $false)]
    [string]$LogPath = 'C:\ProgramData\OficinaBinaria\ioterminal-setup',

    [Parameter(Mandatory = $false)]
    [switch]$Force,

    [Parameter(Mandatory = $false)]
    [switch]$DryRun,

    [Parameter(Mandatory = $false)]
    [switch]$Rollback,

    [Parameter(Mandatory = $false)]
    [switch]$Reinstall,

    [Parameter(Mandatory = $false)]
    [switch]$SkipAvExclusion
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region Constantes

$script:SetupDataDir = 'C:\ProgramData\OficinaBinaria\ioterminal-setup'
$script:StateFileName = 'state.json'
$script:LogFilePath = $null
$script:TranscriptStarted = $false
$script:KitRoot = $null
$script:PackagesRoot = $null
$script:Manifest = $null
$script:WorkDir = $null
$script:InstallDir = $null
$script:RebootPending = $false
$script:AvExclusionFailed = $false
$script:Inventory = $null
$script:KitRevision = '0.3.9'

$script:InstallExitCodes = @{
    'driver_cdm20824'  = 30
    'ioterminal'       = 31
    'license_idmonact' = 32
    'd2xx_runtime'     = 33
}

$script:ValidateExitCodes = @{
    'driver_cdm20824'  = 40
    'ioterminal'       = 41
    'license_idmonact' = 42
    'd2xx_runtime'     = 45
}

#endregion

#region Log

function Write-SetupLog {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level,

        [Parameter(Mandatory = $false)]
        [string]$Component = 'SETUP',

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $timestamp = Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'
    $line = "[$timestamp] [$Level] [$Component] $Message"
    Write-Host $line

    if ($script:LogFilePath -and -not $script:TranscriptStarted) {
        Add-Content -Path $script:LogFilePath -Value $line -Encoding UTF8
    }
}

function Start-SetupLogging {
    $effectiveLogPath = $LogPath
    try {
        if (-not (Test-Path -LiteralPath $effectiveLogPath)) {
            New-Item -ItemType Directory -Path $effectiveLogPath -Force | Out-Null
        }
    }
    catch {
        $effectiveLogPath = $env:TEMP
        Write-Warning "Nao foi possivel criar LogPath '$LogPath'. Usando TEMP: $effectiveLogPath"
    }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $script:LogFilePath = Join-Path $effectiveLogPath "ioterminal-setup_$stamp.log"

    Start-Transcript -Path $script:LogFilePath -Append | Out-Null
    $script:TranscriptStarted = $true
    Write-SetupLog -Level 'INFO' -Message "Log iniciado: $($script:LogFilePath)"
}

function Stop-SetupLogging {
    if ($script:TranscriptStarted) {
        try {
            Stop-Transcript | Out-Null
        }
        catch {
            # transcript ja encerrado
        }
        $script:TranscriptStarted = $false
    }
}

function Exit-Setup {
    param(
        [Parameter(Mandatory = $true)]
        [int]$ExitCode,

        [Parameter(Mandatory = $false)]
        [string]$Component = 'SETUP',

        [Parameter(Mandatory = $false)]
        [string]$Stage = '',

        [Parameter(Mandatory = $false)]
        [string]$Cause = '',

        [Parameter(Mandatory = $false)]
        [string]$Action = ''
    )

    if ($ExitCode -ne 0) {
        $parts = @("Codigo de saida: $ExitCode")
        if ($Component) { $parts += "Componente: $Component" }
        if ($Stage) { $parts += "Etapa: $Stage" }
        if ($Cause) { $parts += "Causa provavel: $Cause" }
        if ($Action) { $parts += "Acao sugerida: $Action" }
        Write-SetupLog -Level 'ERROR' -Component $Component -Message ($parts -join ' | ')
    }

    Stop-SetupLogging
    exit $ExitCode
}

#endregion

#region Utilitarios

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-PowerShellVersion {
    $version = $PSVersionTable.PSVersion
    if ($version.Major -lt 5 -or ($version.Major -eq 5 -and $version.Minor -lt 1)) {
        return $false
    }
    return $true
}

function Get-ObjectProperty {
    param(
        $Object,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $null
    }
    if ($Object.PSObject.Properties.Name -contains $Name) {
        return $Object.$Name
    }
    return $null
}

function Test-HasTodoValue {
    param($Object)

    if ($null -eq $Object) { return $false }

    if ($Object -is [string]) {
        return ($Object -match '(?i)^TODO' -or $Object -match 'TODO-')
    }

    if ($Object -is [System.Collections.IDictionary]) {
        foreach ($key in $Object.Keys) {
            if (Test-HasTodoValue -Object $Object[$key]) { return $true }
        }
        return $false
    }

    if ($Object -is [System.Collections.IEnumerable]) {
        foreach ($item in $Object) {
            if (Test-HasTodoValue -Object $item) { return $true }
        }
        return $false
    }

    if ($Object -is [PSCustomObject]) {
        foreach ($prop in $Object.PSObject.Properties) {
            if (Test-HasTodoValue -Object $prop.Value) { return $true }
        }
    }

    return $false
}

function Get-ManifestTodoFields {
    param(
        $Object,

        [Parameter(Mandatory = $false)]
        [string]$Path = ''
    )

    $results = @()
    if ($null -eq $Object) { return $results }

    if ($Object -is [string]) {
        if ($Object -match '(?i)^TODO' -or $Object -match 'TODO-') { $results += $Path }
        return $results
    }

    if ($Object -is [System.Collections.IEnumerable] -and -not ($Object -is [string])) {
        $index = 0
        foreach ($item in $Object) {
            $results += Get-ManifestTodoFields -Object $item -Path "$Path[$index]"
            $index++
        }
        return $results
    }

    if ($Object -is [PSCustomObject]) {
        foreach ($prop in $Object.PSObject.Properties) {
            $childPath = if ($Path) { "$Path.$($prop.Name)" } else { $prop.Name }
            $results += Get-ManifestTodoFields -Object $prop.Value -Path $childPath
        }
    }

    return $results
}

function ConvertTo-HashtableRecursive {
    param($InputObject)

    if ($null -eq $InputObject) { return $null }

    if ($InputObject -is [System.Collections.IDictionary]) {
        $table = @{}
        foreach ($key in $InputObject.Keys) {
            $table[$key] = ConvertTo-HashtableRecursive -InputObject $InputObject[$key]
        }
        return $table
    }

    if ($InputObject -is [System.Collections.IEnumerable] -and -not ($InputObject -is [string])) {
        $list = @()
        foreach ($item in $InputObject) {
            $list += , (ConvertTo-HashtableRecursive -InputObject $item)
        }
        return $list
    }

    if ($InputObject -is [PSCustomObject]) {
        $table = @{}
        foreach ($prop in $InputObject.PSObject.Properties) {
            $table[$prop.Name] = ConvertTo-HashtableRecursive -InputObject $prop.Value
        }
        return $table
    }

    return $InputObject
}

function Get-System32Directory {
    return (Join-Path $env:SystemRoot 'System32')
}

function Get-SysWow64Directory {
    $wow64 = Join-Path $env:SystemRoot 'SysWOW64'
    if (Test-Path -LiteralPath $wow64) { return $wow64 }
    # Windows 32 bits nao tem SysWOW64: o destino correto e o System32 real.
    return (Get-System32Directory)
}

function Expand-PathToken {
    param([string]$Value)

    if (-not $Value) { return $Value }
    if ($script:InstallDir) {
        $Value = $Value.Replace('{installDir}', $script:InstallDir)
    }
    $Value = $Value.Replace('{system32}', (Get-System32Directory))
    $Value = $Value.Replace('{syswow64}', (Get-SysWow64Directory))
    return $Value
}

#endregion

#region Estado

function Get-StateFilePath {
    return Join-Path $script:SetupDataDir $script:StateFileName
}

function Get-SetupState {
    $statePath = Get-StateFilePath
    if (-not (Test-Path -LiteralPath $statePath)) {
        return @{ packageVersion = $null; components = @() }
    }

    try {
        $raw = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
        return ConvertTo-HashtableRecursive -InputObject $raw
    }
    catch {
        Write-SetupLog -Level 'WARN' -Message "state.json ilegivel, sera recriado: $($_.Exception.Message)"
        return @{ packageVersion = $null; components = @() }
    }
}

function Save-SetupState {
    param([Parameter(Mandatory = $true)]$State)

    $stateDir = Split-Path -Parent (Get-StateFilePath)
    if (-not (Test-Path -LiteralPath $stateDir)) {
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    }

    $State | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Get-StateFilePath) -Encoding UTF8
}

function Update-ComponentState {
    param(
        [Parameter(Mandatory = $true)][string]$ComponentId,
        [Parameter(Mandatory = $true)][string]$PackageVersion,
        [Parameter(Mandatory = $true)][bool]$InstalledByTool,
        [Parameter(Mandatory = $false)]$UninstallInfo,
        [Parameter(Mandatory = $false)][string]$InstallDir
    )

    $state = Get-SetupState
    $components = @($state.components | Where-Object { $_ -and $_.id -ne $ComponentId })

    $components += @{
        id              = $ComponentId
        packageVersion  = $PackageVersion
        timestamp       = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
        installedByTool = $InstalledByTool
        uninstall       = $UninstallInfo
        installDir      = $InstallDir
    }

    $state.components = $components
    $state.packageVersion = $PackageVersion
    Save-SetupState -State $state
}

function Remove-ComponentFromState {
    param([Parameter(Mandatory = $true)][string]$ComponentId)

    $state = Get-SetupState
    $state.components = @($state.components | Where-Object { $_ -and $_.id -ne $ComponentId })
    Save-SetupState -State $state
}

function Get-StateInstallDir {
    $state = Get-SetupState
    $entry = @($state.components | Where-Object { $_ -and $_.id -eq 'ioterminal' }) | Select-Object -First 1
    if ($entry) {
        $dir = Get-ObjectProperty -Object $entry -Name 'installDir'
        if ($dir) { return [string]$dir }
    }
    return $null
}

#endregion

#region Inventario

function Get-EnvironmentInventory {
    Write-SetupLog -Level 'INFO' -Component 'INVENTORY' -Message 'Coletando inventario de ambiente...'

    $inventory = @{}

    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem
        $inventory.OSCaption = $os.Caption
        $inventory.OSBuild = $os.BuildNumber
        $inventory.OSArchitecture = $os.OSArchitecture
    }
    catch {
        $inventory.OSCaption = 'desconhecido'
    }

    $inventory.PowerShellVersion = $PSVersionTable.PSVersion.ToString()

    try {
        $inventory.SecureBootEnabled = Confirm-SecureBootUEFI
    }
    catch {
        $inventory.SecureBootEnabled = $null
    }

    try {
        $hvciPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity'
        $hvci = Get-ItemProperty -Path $hvciPath -ErrorAction SilentlyContinue
        $inventory.HVCIEnabled = if ($hvci -and $null -ne $hvci.Enabled) { [bool]$hvci.Enabled } else { $false }
    }
    catch {
        $inventory.HVCIEnabled = $null
    }

    try {
        $avProducts = Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction SilentlyContinue
        $inventory.AntiVirusProducts = @($avProducts | ForEach-Object { @{ displayName = $_.displayName } })
    }
    catch {
        $inventory.AntiVirusProducts = @()
    }

    try {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem
        $inventory.PartOfDomain = [bool]$cs.PartOfDomain
        $inventory.Domain = $cs.Domain
    }
    catch {
        $inventory.PartOfDomain = $null
    }

    try {
        $inventory.FreeDiskBytes = [long](Get-PSDrive -Name C -ErrorAction Stop).Free
    }
    catch {
        $inventory.FreeDiskBytes = 0
    }

    foreach ($key in ($inventory.Keys | Sort-Object)) {
        $value = $inventory[$key]
        if ($value -is [System.Collections.IEnumerable] -and -not ($value -is [string])) {
            Write-SetupLog -Level 'INFO' -Component 'INVENTORY' -Message "${key}: $($value | ConvertTo-Json -Compress -Depth 4)"
        }
        else {
            Write-SetupLog -Level 'INFO' -Component 'INVENTORY' -Message "${key}: $value"
        }
    }

    return $inventory
}

function Test-EnvironmentPreconditions {
    param([Parameter(Mandatory = $true)]$Manifest)

    if (-not (Test-PowerShellVersion)) {
        Exit-Setup -ExitCode 13 `
            -Stage 'pre-condicao' `
            -Cause "PowerShell $($PSVersionTable.PSVersion) inferior a 5.1" `
            -Action 'Execute em PowerShell 5.1 Desktop ou superior.'
    }

    $minFree = Get-ObjectProperty -Object $Manifest -Name 'minFreeDiskBytes'
    if ($minFree -and $script:Inventory.FreeDiskBytes -lt [long]$minFree) {
        $freeGb = [math]::Round($script:Inventory.FreeDiskBytes / 1GB, 2)
        $needGb = [math]::Round([long]$minFree / 1GB, 2)
        Exit-Setup -ExitCode 14 `
            -Stage 'pre-condicao' `
            -Cause "Espaco livre insuficiente ($freeGb GB livre, $needGb GB exigidos)" `
            -Action 'Libere espaco no disco C: e execute novamente.'
    }
}

function Get-AttributedFailureExitCode {
    param(
        [Parameter(Mandatory = $true)][int]$DefaultExitCode,
        [Parameter(Mandatory = $false)][string]$Stage = ''
    )

    if ($script:Inventory.PartOfDomain -eq $true -and $Stage -match 'instalacao|extracao') {
        return 51
    }

    $thirdPartyAv = @($script:Inventory.AntiVirusProducts | Where-Object {
        $_.displayName -and ($_.displayName -notmatch '(?i)windows defender|microsoft defender')
    })

    if (($thirdPartyAv.Count -gt 0 -or $script:AvExclusionFailed) -and $Stage -match 'instalacao|extracao') {
        return 50
    }

    return $DefaultExitCode
}

#endregion

#region Manifesto e pacotes

function Get-SetupKitRoot {
    $candidates = @()
    if ($PSScriptRoot) { $candidates += $PSScriptRoot }
    if ($PSCommandPath) { $candidates += (Split-Path -Parent $PSCommandPath) }

    try {
        $main = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        if ($main -and ([IO.Path]::GetFileNameWithoutExtension($main)) -notmatch '(?i)^powershell') {
            $candidates += Split-Path -Parent $main
        }
    }
    catch {
    }

    $candidates += (Get-Location).Path

    foreach ($dir in $candidates) {
        if ($dir -and (Test-Path -LiteralPath (Join-Path $dir 'manifest.json'))) {
            return $dir
        }
    }

    return (Get-Location).Path
}

function Get-ManifestContent {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        Exit-Setup -ExitCode 12 `
            -Stage 'manifesto' `
            -Cause "Manifesto nao encontrado: $Path" `
            -Action 'Execute o installer.ps1 da pasta do kit (com manifest.json ao lado).'
    }

    try {
        return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
    }
    catch {
        Exit-Setup -ExitCode 12 `
            -Stage 'manifesto' `
            -Cause "JSON invalido: $($_.Exception.Message)" `
            -Action 'Corrija a sintaxe do manifest.json.'
    }
}

function Test-ManifestStructure {
    param([Parameter(Mandatory = $true)]$Manifest)

    if ($null -eq (Get-ObjectProperty -Object $Manifest -Name 'schemaVersion')) {
        Exit-Setup -ExitCode 12 -Stage 'manifesto' -Cause 'Campo schemaVersion ausente' -Action 'Corrija manifest.json.'
    }

    $components = @(Get-ObjectProperty -Object $Manifest -Name 'components')
    if ($components.Count -eq 0) {
        Exit-Setup -ExitCode 12 -Stage 'manifesto' -Cause 'Lista components vazia ou ausente' -Action 'Corrija manifest.json.'
    }

    $validKinds = @('driver-archive', 'portable-archive', 'dll-copy', 'license-copy')
    foreach ($component in $components) {
        $id = Get-ObjectProperty -Object $component -Name 'id'
        if (-not $id) {
            Exit-Setup -ExitCode 12 -Stage 'manifesto' -Cause 'Componente sem id' -Action 'Corrija manifest.json.'
        }
        if ($null -eq (Get-ObjectProperty -Object $component -Name 'order')) {
            Exit-Setup -ExitCode 12 -Stage 'manifesto' -Cause "Componente '$id' sem order" -Action 'Corrija manifest.json.'
        }
        $kind = Get-ObjectProperty -Object $component -Name 'kind'
        if ($kind -notin $validKinds) {
            Exit-Setup -ExitCode 12 `
                -Stage 'manifesto' `
                -Cause "Componente '$id' com kind invalido: $kind" `
                -Action "Use um destes: $($validKinds -join ', ')."
        }
    }
}

function Get-PackagesRoot {
    param([Parameter(Mandatory = $true)]$Manifest)

    if ($PackageDir) {
        if (-not (Test-Path -LiteralPath $PackageDir)) {
            Exit-Setup -ExitCode 20 `
                -Stage 'pacote' `
                -Cause "PackageDir informado nao existe: $PackageDir" `
                -Action 'Informe uma pasta valida em -PackageDir.'
        }
        return (Resolve-Path -LiteralPath $PackageDir).Path
    }

    $packageRoot = Get-ObjectProperty -Object $Manifest -Name 'packageRoot'
    if ($packageRoot) {
        $candidate = Join-Path $script:KitRoot $packageRoot
        if (Test-Path -LiteralPath $candidate) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
        Exit-Setup -ExitCode 20 `
            -Stage 'pacote' `
            -Cause "Pasta de pacotes ausente: $candidate" `
            -Action 'Copie a pasta de pacotes para o kit ou use -PackageDir.'
    }

    return $script:KitRoot
}

function Resolve-PackageItem {
    param(
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$ComponentId
    )

    $path = if ([IO.Path]::IsPathRooted($RelativePath)) {
        $RelativePath
    }
    else {
        Join-Path $script:PackagesRoot $RelativePath
    }

    if (-not (Test-Path -LiteralPath $path)) {
        Exit-Setup -ExitCode 20 `
            -Component $ComponentId `
            -Stage 'pacote' `
            -Cause "Arquivo ou pasta ausente: $path" `
            -Action 'Confira o kit; nao renomeie as pastas de pacotes.'
    }

    return (Resolve-Path -LiteralPath $path).Path
}

function Test-PackageIntegrity {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $false)][string]$ExpectedSha256,
        [Parameter(Mandatory = $true)][string]$ComponentId
    )

    if (-not $ExpectedSha256 -or (Test-HasTodoValue -Object $ExpectedSha256)) {
        Write-SetupLog -Level 'WARN' -Component $ComponentId -Message 'sha256 nao definido no manifesto: integridade nao verificada.'
        return
    }

    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-SetupLog -Level 'INFO' -Component $ComponentId -Message "SHA-256: $actual"

    if ($actual -ne $ExpectedSha256.ToLowerInvariant()) {
        Exit-Setup -ExitCode 21 `
            -Component $ComponentId `
            -Stage 'integridade' `
            -Cause "SHA-256 divergente do manifesto (esperado $($ExpectedSha256.ToLowerInvariant()))" `
            -Action 'Reponha o arquivo original do kit ou atualize o sha256 no manifesto.'
    }
}

#endregion

#region Extracao

function Initialize-WorkDirectory {
    if ($script:WorkDir) { return $script:WorkDir }

    $dir = Join-Path $env:TEMP "ioterminal-setup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $script:WorkDir = $dir
    Write-SetupLog -Level 'INFO' -Message "Diretorio de trabalho: $dir"
    return $dir
}

function Get-BundledArchiveTool {
    $spec = Get-ObjectProperty -Object $script:Manifest -Name 'bundledExtractor'
    if (-not $spec) { return $null }

    $file = [string](Get-ObjectProperty -Object $spec -Name 'file')
    if (-not $file) { return $null }

    $path = if ([IO.Path]::IsPathRooted($file)) { $file } else { Join-Path $script:KitRoot $file }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Write-SetupLog -Level 'WARN' -Component 'EXTRATOR' -Message "Extrator do kit ausente: $path"
        return $null
    }

    # O 7-Zip nao e assinado pelo autor, e este binario roda elevado: a unica
    # garantia possivel e o hash declarado no manifesto.
    foreach ($item in @(
        @{ path = $path; sha = [string](Get-ObjectProperty -Object $spec -Name 'sha256') },
        @{ path = (Join-Path (Split-Path -Parent $path) ([string](Get-ObjectProperty -Object $spec -Name 'libraryFile'))); sha = [string](Get-ObjectProperty -Object $spec -Name 'librarySha256') }
    )) {
        if (-not $item.sha) { continue }
        if (-not (Test-Path -LiteralPath $item.path -PathType Leaf)) {
            Exit-Setup -ExitCode 20 -Component 'EXTRATOR' -Stage 'integridade' `
                -Cause "Arquivo do extrator ausente: $($item.path)" `
                -Action 'Reponha a pasta ferramentas do kit original.'
        }

        $actual = (Get-FileHash -LiteralPath $item.path -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $item.sha.ToLowerInvariant()) {
            Exit-Setup -ExitCode 21 -Component 'EXTRATOR' -Stage 'integridade' `
                -Cause "SHA-256 divergente em $(Split-Path -Leaf $item.path)" `
                -Action 'Nao execute este kit: reponha a pasta ferramentas do kit original.'
        }
    }

    Write-SetupLog -Level 'INFO' -Component 'EXTRATOR' -Message "Extrator do kit verificado: $path"
    return @{ kind = '7zip'; path = $path }
}

function Get-ArchiveTool {
    $bundled = Get-BundledArchiveTool
    if ($bundled) { return $bundled }

    $candidates = @(
        @{ kind = '7zip';  path = 'C:\Program Files\7-Zip\7z.exe' },
        @{ kind = '7zip';  path = 'C:\Program Files (x86)\7-Zip\7z.exe' },
        @{ kind = 'unrar'; path = 'C:\Program Files\WinRAR\UnRAR.exe' },
        @{ kind = 'unrar'; path = 'C:\Program Files (x86)\WinRAR\UnRAR.exe' },
        @{ kind = 'winrar'; path = 'C:\Program Files\WinRAR\WinRAR.exe' },
        @{ kind = 'winrar'; path = 'C:\Program Files (x86)\WinRAR\WinRAR.exe' }
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate.path) {
            return $candidate
        }
    }

    foreach ($name in @('7z.exe', '7za.exe', 'UnRAR.exe', 'WinRAR.exe')) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd) {
            $kind = if ($name -match '(?i)^7z') { '7zip' } elseif ($name -match '(?i)unrar') { 'unrar' } else { 'winrar' }
            return @{ kind = $kind; path = $cmd.Source }
        }
    }

    return $null
}

function Expand-ArchiveFile {
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$ComponentId,
        [Parameter(Mandatory = $false)][int]$TimeoutSeconds = 600
    )

    $tool = Get-ArchiveTool
    if (-not $tool) {
        Exit-Setup -ExitCode 22 `
            -Component $ComponentId `
            -Stage 'extracao' `
            -Cause 'Nenhum extrator de .rar encontrado (7-Zip ou WinRAR)' `
            -Action 'Instale o 7-Zip (https://www.7-zip.org) e execute novamente.'
    }

    if (-not (Test-Path -LiteralPath $Destination)) {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    }

    $argList = switch ($tool.kind) {
        '7zip'  { @('x', '-y', "-o$Destination", $ArchivePath) }
        'unrar' { @('x', '-y', $ArchivePath, "$Destination\") }
        default { @('x', '-y', '-ibck', $ArchivePath, "$Destination\") }
    }

    Write-SetupLog -Level 'INFO' -Component $ComponentId -Message "Extraindo com $($tool.kind): $(Split-Path -Leaf $ArchivePath)"

    $exitCode = Start-ProcessWithTimeout -FilePath $tool.path -Arguments $argList -TimeoutSeconds $TimeoutSeconds -ComponentId $ComponentId
    if ($exitCode -ne 0) {
        $attributed = Get-AttributedFailureExitCode -DefaultExitCode 23 -Stage 'extracao'
        Exit-Setup -ExitCode $attributed `
            -Component $ComponentId `
            -Stage 'extracao' `
            -Cause "Extrator retornou codigo $exitCode" `
            -Action 'Confira a integridade do arquivo e as exclusoes do antivirus.'
    }

    return $Destination
}

function Get-FlattenedRoot {
    param([Parameter(Mandatory = $true)][string]$Path)

    $files = @(Get-ChildItem -LiteralPath $Path -File -ErrorAction SilentlyContinue)
    $dirs = @(Get-ChildItem -LiteralPath $Path -Directory -ErrorAction SilentlyContinue)

    if ($files.Count -eq 0 -and $dirs.Count -eq 1) {
        return (Get-FlattenedRoot -Path $dirs[0].FullName)
    }

    return $Path
}

function Get-QuotedArgumentLine {
    param([Parameter(Mandatory = $false)][string[]]$Arguments = @())

    $parts = foreach ($argument in $Arguments) {
        if ($null -eq $argument -or $argument -eq '') { continue }
        if ($argument -notmatch '\s') { $argument; continue }

        # Chaveados como -oC:\pasta com espaco exigem as aspas apenas no valor.
        if ($argument -match '^(-o|/DIR=|/LOG=)(.*)$') {
            '{0}"{1}"' -f $Matches[1], $Matches[2].Trim('"')
        }
        else {
            '"{0}"' -f $argument.Trim('"')
        }
    }

    return (@($parts) -join ' ')
}

function Start-ProcessWithTimeout {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $false)][string[]]$Arguments = @(),
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds,
        [Parameter(Mandatory = $true)][string]$ComponentId
    )

    $argumentLine = Get-QuotedArgumentLine -Arguments $Arguments
    Write-SetupLog -Level 'INFO' -Component $ComponentId -Message "Executando: `"$FilePath`" $argumentLine"

    # System.Diagnostics.Process e usado em vez de Start-Process porque garante
    # ExitCode e permite capturar a saida do processo para o log.
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = $argumentLine
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true

    $workDir = Split-Path -Parent $FilePath
    if ($workDir -and (Test-Path -LiteralPath $workDir)) { $psi.WorkingDirectory = $workDir }

    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
    }
    catch {
        Write-SetupLog -Level 'ERROR' -Component $ComponentId -Message "Falha ao iniciar processo: $($_.Exception.Message)"
        return -1
    }

    if ($null -eq $proc) {
        Write-SetupLog -Level 'ERROR' -Component $ComponentId -Message 'Processo nao iniciou.'
        return -1
    }

    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()

    if (-not $proc.WaitForExit([Math]::Max(1000, $TimeoutSeconds * 1000))) {
        Write-SetupLog -Level 'WARN' -Component $ComponentId -Message "Timeout de ${TimeoutSeconds}s. Encerrando PID $($proc.Id)."
        try { $proc.Kill() } catch { }
        return -2
    }

    foreach ($task in @($stdoutTask, $stderrTask)) {
        $text = $task.Result
        if (-not $text) { continue }
        foreach ($line in ($text -split "`r?`n" | Where-Object { $_.Trim() })) {
            Write-SetupLog -Level 'INFO' -Component $ComponentId -Message "saida: $($line.Trim())"
        }
    }

    $exitCode = $proc.ExitCode
    Write-SetupLog -Level 'INFO' -Component $ComponentId -Message "Exit code: $exitCode"
    return $exitCode
}

#endregion

#region Motor de predicados

function Get-PublishedDriverBlocks {
    param(
        [Parameter(Mandatory = $true)][string]$OriginalName,
        [Parameter(Mandatory = $false)][string]$DriverVersion,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[string]]$Result
    )

    try {
        $output = & pnputil.exe /enum-drivers 2>&1 | Out-String
    }
    catch {
        return
    }

    # A saida do pnputil e traduzida conforme o idioma do Windows; por isso os blocos
    # sao separados por linha vazia e os campos localizados nunca sao usados como chave.
    foreach ($block in ($output -split "(`r?`n){2,}")) {
        if ($block -notmatch [regex]::Escape($OriginalName)) { continue }

        # Windows traz varias versoes FTDI de fabrica; sem filtro de versao o kit
        # seria considerado instalado por causa de um driver que nao e o do kit.
        if ($DriverVersion -and $block -notmatch ([regex]::Escape($DriverVersion) + '(\D|$)')) { continue }

        $Result.Add($block)
    }
}

function Test-Predicate {
    param([Parameter(Mandatory = $true)]$Predicate)

    $type = Get-ObjectProperty -Object $Predicate -Name 'type'
    if (-not $type -or (Test-HasTodoValue -Object $Predicate)) { return $false }

    switch ($type) {
        'file' {
            $path = Expand-PathToken -Value ([string](Get-ObjectProperty -Object $Predicate -Name 'path'))
            if (-not $path -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }

            $minVersion = Get-ObjectProperty -Object $Predicate -Name 'minVersion'
            if ($minVersion) {
                $info = (Get-Item -LiteralPath $path).VersionInfo
                if (-not $info -or -not $info.FileVersion) { return $false }
                return ([version]$info.FileVersion -ge [version]$minVersion)
            }

            return $true
        }

        'dir' {
            $path = Expand-PathToken -Value ([string](Get-ObjectProperty -Object $Predicate -Name 'path'))
            if (-not $path -or -not (Test-Path -LiteralPath $path -PathType Container)) { return $false }

            $pattern = Get-ObjectProperty -Object $Predicate -Name 'containsPattern'
            if (-not $pattern) { return $true }

            $recurse = [bool](Get-ObjectProperty -Object $Predicate -Name 'recurse')
            $found = @(Get-ChildItem -LiteralPath $path -Filter $pattern -File -Recurse:$recurse -ErrorAction SilentlyContinue)
            return ($found.Count -gt 0)
        }

        'driver' {
            $originalName = [string](Get-ObjectProperty -Object $Predicate -Name 'originalName')
            if (-not $originalName) { return $false }

            $driverVersion = [string](Get-ObjectProperty -Object $Predicate -Name 'driverVersion')
            $blocks = New-Object 'System.Collections.Generic.List[string]'
            Get-PublishedDriverBlocks -OriginalName $originalName -DriverVersion $driverVersion -Result $blocks
            return ($blocks.Count -gt 0)
        }

        'registry' {
            $path = [string](Get-ObjectProperty -Object $Predicate -Name 'path')
            if (-not $path -or -not (Test-Path -LiteralPath $path)) { return $false }

            $name = Get-ObjectProperty -Object $Predicate -Name 'name'
            if (-not $name) { return $true }

            $value = Get-ItemProperty -LiteralPath $path -Name $name -ErrorAction SilentlyContinue
            if ($null -eq $value) { return $false }

            $expected = Get-ObjectProperty -Object $Predicate -Name 'expectedValue'
            if ($expected) { return ("$($value.$name)" -eq "$expected") }

            return $true
        }

        'service' {
            $name = [string](Get-ObjectProperty -Object $Predicate -Name 'name')
            if (-not $name) { return $false }

            $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
            if (-not $svc) { return $false }

            $state = Get-ObjectProperty -Object $Predicate -Name 'state'
            if ($state) { return ($svc.Status.ToString() -eq $state) }

            return $true
        }

        default {
            Write-SetupLog -Level 'WARN' -Component 'PREDICATE' -Message "Tipo de predicado desconhecido: $type"
            return $false
        }
    }
}

function Write-PredicateFailureDetail {
    param(
        [Parameter(Mandatory = $true)]$Predicate,
        [Parameter(Mandatory = $true)][string]$ComponentId
    )

    $type = Get-ObjectProperty -Object $Predicate -Name 'type'

    if ($type -eq 'driver') {
        $originalName = [string](Get-ObjectProperty -Object $Predicate -Name 'originalName')
        $driverVersion = [string](Get-ObjectProperty -Object $Predicate -Name 'driverVersion')
        Write-SetupLog -Level 'WARN' -Component $ComponentId -Message "Driver '$originalName' versao '$driverVersion' nao esta publicado no DriverStore."

        $outras = New-Object 'System.Collections.Generic.List[string]'
        Get-PublishedDriverBlocks -OriginalName $originalName -Result $outras
        foreach ($block in $outras) {
            $version = ([regex]::Match($block, '\d+\.\d+\.\d+\.\d+')).Value
            $published = ([regex]::Match($block, '(?i)oem\d+\.inf')).Value
            Write-SetupLog -Level 'INFO' -Component $ComponentId -Message "Outra versao presente: $published versao $version"
        }
        return
    }

    $path = Expand-PathToken -Value ([string](Get-ObjectProperty -Object $Predicate -Name 'path'))
    if ($path) {
        Write-SetupLog -Level 'WARN' -Component $ComponentId -Message "Caminho esperado ausente: $path"
        $parent = Split-Path -Parent $path
        if ($parent) {
            Write-SetupLog -Level 'INFO' -Component $ComponentId -Message "Pasta pai existe: $(Test-Path -LiteralPath $parent) ($parent)"
        }
    }
}

function Test-PredicateList {
    param(
        [Parameter(Mandatory = $true)][AllowNull()]$Predicates,
        [Parameter(Mandatory = $true)][string]$ComponentId,
        [Parameter(Mandatory = $true)][string]$Purpose
    )

    $list = @($Predicates)
    if ($list.Count -eq 0) {
        Write-SetupLog -Level 'WARN' -Component $ComponentId -Message "Lista $Purpose vazia: considerado falso."
        return $false
    }

    $index = 0
    foreach ($predicate in $list) {
        $result = Test-Predicate -Predicate $predicate
        $type = Get-ObjectProperty -Object $predicate -Name 'type'
        Write-SetupLog -Level 'INFO' -Component $ComponentId -Message "${Purpose}[$index] tipo=${type}: $(if ($result) { 'OK' } else { 'FALHA' })"

        if (-not $result) {
            Write-PredicateFailureDetail -Predicate $predicate -ComponentId $ComponentId
            return $false
        }

        $index++
    }

    return $true
}

function Get-OsBuildNumber {
    if ($script:Inventory -and $script:Inventory.OSBuild) {
        $parsed = 0
        if ([int]::TryParse([string]$script:Inventory.OSBuild, [ref]$parsed)) { return $parsed }
    }

    try {
        return [int](Get-CimInstance -ClassName Win32_OperatingSystem).BuildNumber
    }
    catch {
        return 0
    }
}

function Test-SkipLegacyKernelDriver {
    param([Parameter(Mandatory = $true)]$Component)

    if ([string]$Component.kind -ne 'driver-archive') { return $false }

    $buildMinimo = Get-ObjectProperty -Object $Component -Name 'skipKernelBuild'
    $build = Get-OsBuildNumber
    if ($buildMinimo -and $build -ge [int]$buildMinimo) { return $true }

    if ($script:Inventory -and $script:Inventory.HVCIEnabled) { return $true }

    return $false
}

function Test-LegacyKernelPublished {
    param([Parameter(Mandatory = $true)]$Component)

    $spec = Get-ObjectProperty -Object $Component -Name 'uninstall'
    $names = @(Get-ObjectProperty -Object $spec -Name 'originalNames' | Where-Object { $_ })
    $version = [string](Get-ObjectProperty -Object $spec -Name 'driverVersion')
    if (@($names).Count -eq 0) { return $false }

    foreach ($name in $names) {
        $blocos = New-Object 'System.Collections.Generic.List[string]'
        Get-PublishedDriverBlocks -OriginalName ([string]$name) -DriverVersion $version -Result $blocos
        if ($blocos.Count -gt 0) { return $true }
    }

    return $false
}

function Test-PublishedDriverMinVersion {
    param(
        [Parameter(Mandatory = $true)][string]$OriginalName,
        [Parameter(Mandatory = $true)][string]$MinVersion
    )

    $minimo = [version]'0.0'
    if (-not [version]::TryParse($MinVersion, [ref]$minimo)) { return $false }

    $blocks = New-Object 'System.Collections.Generic.List[string]'
    Get-PublishedDriverBlocks -OriginalName $OriginalName -Result $blocks

    foreach ($block in $blocks) {
        $texto = ([regex]::Match([string]$block, '\d+\.\d+\.\d+(?:\.\d+)?')).Value
        if (-not $texto) { continue }

        $versao = [version]'0.0'
        if ([version]::TryParse($texto, [ref]$versao) -and $versao -ge $minimo) {
            return $true
        }
    }

    return $false
}

function Test-ModernFtdiKernelPublished {
    param([Parameter(Mandatory = $false)][string]$MinVersion = '2.12.0.0')

    return (Test-PublishedDriverMinVersion -OriginalName 'ftdibus.inf' -MinVersion $MinVersion)
}

function Test-ComponentDetect {
    param([Parameter(Mandatory = $true)]$Component)

    if (Test-SkipLegacyKernelDriver -Component $Component) {
        $legado = Test-LegacyKernelPublished -Component $Component
        $moderno = Test-ModernFtdiKernelPublished
        Write-SetupLog -Level 'INFO' -Component $Component.id -Message "detect kernel legado 2.08.24: $(if ($legado) { 'PRESENTE (sera removido)' } else { 'AUSENTE' })"
        Write-SetupLog -Level 'INFO' -Component $Component.id -Message "detect kernel WHQL 2.12+: $(if ($moderno) { 'PRESENTE' } else { 'AUSENTE (sera publicado)' })"
        if ($legado) { return $false }
        return $moderno
    }

    return (Test-PredicateList -Predicates (Get-ObjectProperty -Object $Component -Name 'detect') -ComponentId $Component.id -Purpose 'detect')
}

function Test-ComponentValidate {
    param([Parameter(Mandatory = $true)]$Component)

    if (Test-SkipLegacyKernelDriver -Component $Component) {
        $legado = Test-LegacyKernelPublished -Component $Component
        $moderno = Test-ModernFtdiKernelPublished
        Write-SetupLog -Level 'INFO' -Component $Component.id -Message "validate kernel legado 2.08.24: $(if ($legado) { 'AINDA PRESENTE' } else { 'AUSENTE (OK)' })"
        Write-SetupLog -Level 'INFO' -Component $Component.id -Message "validate kernel WHQL 2.12+: $(if ($moderno) { 'PRESENTE (OK)' } else { 'AUSENTE' })"
        return ((-not $legado) -and $moderno)
    }

    return (Test-PredicateList -Predicates (Get-ObjectProperty -Object $Component -Name 'validate') -ComponentId $Component.id -Purpose 'validate')
}

#endregion

#region Antivirus

function Add-AntivirusExclusions {
    param([Parameter(Mandatory = $false)][string[]]$Paths = @())

    if ($SkipAvExclusion) {
        Write-SetupLog -Level 'INFO' -Component 'AV' -Message 'Exclusoes de antivirus ignoradas (-SkipAvExclusion).'
        return
    }

    foreach ($av in @($script:Inventory.AntiVirusProducts | Where-Object {
        $_.displayName -and ($_.displayName -notmatch '(?i)windows defender|microsoft defender')
    })) {
        Write-SetupLog -Level 'WARN' -Component 'AV' -Message "Antivirus de terceiros detectado: $($av.displayName). Configure exclusao manual se houver bloqueio."
    }

    foreach ($path in ($Paths | Where-Object { $_ } | Select-Object -Unique)) {
        try {
            Add-MpPreference -ExclusionPath $path -ErrorAction Stop
            Write-SetupLog -Level 'INFO' -Component 'AV' -Message "Exclusao Defender adicionada: $path"
        }
        catch {
            $script:AvExclusionFailed = $true
            Write-SetupLog -Level 'WARN' -Component 'AV' -Message "Falha ao excluir $path no Defender: $($_.Exception.Message)"
        }
    }
}

#endregion

#region Instalacao do driver

function Get-DriverPackageDirectory {
    param([Parameter(Mandatory = $true)]$Component)

    $id = [string]$Component.id
    $timeout = [int](Get-ObjectProperty -Object $Component -Name 'timeoutSeconds')
    if ($timeout -le 0) { $timeout = 600 }

    $workDir = Initialize-WorkDirectory
    $driverDir = Join-Path $workDir "$id-driver"

    # Mais de um componente usa o conteudo deste pacote (driver e DLL D2XX);
    # extrair uma vez por execucao evita repetir trabalho e conferencia de hash.
    if (Test-Path -LiteralPath $driverDir) {
        return $driverDir
    }

    $archive = Resolve-PackageItem -RelativePath ([string]$Component.archive) -ComponentId $id
    Test-PackageIntegrity -Path $archive -ExpectedSha256 ([string](Get-ObjectProperty -Object $Component -Name 'sha256')) -ComponentId $id

    $outerDir = Join-Path $workDir "$id-pacote"
    Expand-ArchiveFile -ArchivePath $archive -Destination $outerDir -ComponentId $id -TimeoutSeconds $timeout | Out-Null

    $patterns = @(Get-ObjectProperty -Object $Component -Name 'innerExeMatch')
    if ($patterns.Count -eq 0) { $patterns = @('*.exe') }

    $innerExe = $null
    foreach ($pattern in $patterns) {
        $innerExe = Get-ChildItem -LiteralPath $outerDir -Filter $pattern -File -Recurse -ErrorAction SilentlyContinue |
            Sort-Object FullName | Select-Object -First 1
        if ($innerExe) { break }
    }

    if (-not $innerExe) {
        Exit-Setup -ExitCode 24 `
            -Component $id `
            -Stage 'extracao' `
            -Cause "Nenhum executavel do driver encontrado em $outerDir" `
            -Action 'Ajuste innerExeMatch no manifest.json.'
    }

    Test-PackageIntegrity -Path $innerExe.FullName -ExpectedSha256 ([string](Get-ObjectProperty -Object $Component -Name 'innerSha256')) -ComponentId $id

    # O pacote FTDI vem embalado num executavel nao assinado; extrair o conteudo
    # evita executar esse wrapper e torna o resultado verificavel.
    Expand-ArchiveFile -ArchivePath $innerExe.FullName -Destination $driverDir -ComponentId $id -TimeoutSeconds $timeout | Out-Null

    return $driverDir
}

function Get-ModernDriverPackageDirectory {
    param([Parameter(Mandatory = $true)]$Component)

    $id = [string]$Component.id
    $timeout = [int](Get-ObjectProperty -Object $Component -Name 'timeoutSeconds')
    if ($timeout -le 0) { $timeout = 600 }

    $workDir = Initialize-WorkDirectory
    $driverDir = Join-Path $workDir "$id-driver-moderno"
    if (Test-Path -LiteralPath $driverDir) {
        return (Get-FlattenedRoot -Path $driverDir)
    }

    $relativo = [string](Get-ObjectProperty -Object $Component -Name 'modernArchive')
    if (-not $relativo) {
        Exit-Setup -ExitCode 12 -Component $id -Stage 'manifesto' `
            -Cause 'Windows 11 exige modernArchive no manifesto' `
            -Action 'Use o kit 0.3.9 ou posterior (pacote DRIVERS\CDM21236.zip).'
    }

    $archive = Resolve-PackageItem -RelativePath $relativo -ComponentId $id
    Test-PackageIntegrity -Path $archive -ExpectedSha256 ([string](Get-ObjectProperty -Object $Component -Name 'modernSha256')) -ComponentId $id
    Expand-ArchiveFile -ArchivePath $archive -Destination $driverDir -ComponentId $id -TimeoutSeconds $timeout | Out-Null

    return (Get-FlattenedRoot -Path $driverDir)
}

function Publish-DriverInfFiles {
    param(
        [Parameter(Mandatory = $true)]$Component,
        [Parameter(Mandatory = $true)][string]$DriverDir
    )

    $id = [string]$Component.id
    $timeout = [int](Get-ObjectProperty -Object $Component -Name 'timeoutSeconds')
    if ($timeout -le 0) { $timeout = 600 }

    $infNames = @(Get-ObjectProperty -Object $Component -Name 'driverInf')
    if ($infNames.Count -eq 0) { $infNames = @('*.inf') }

    $installed = 0
    foreach ($infName in $infNames) {
        $inf = Get-ChildItem -LiteralPath $DriverDir -Filter $infName -File -Recurse -ErrorAction SilentlyContinue |
            Sort-Object FullName | Select-Object -First 1

        if (-not $inf) {
            Exit-Setup -ExitCode 24 `
                -Component $id `
                -Stage 'extracao' `
                -Cause "Arquivo .inf '$infName' ausente no pacote extraido" `
                -Action 'Confira driverInf no manifest.json e a integridade do pacote.'
        }

        $exitCode = Start-ProcessWithTimeout `
            -FilePath "$env:SystemRoot\System32\pnputil.exe" `
            -Arguments @('/add-driver', $inf.FullName, '/install', '/subdirs') `
            -TimeoutSeconds $timeout `
            -ComponentId $id

        if ($exitCode -eq 3010) {
            $script:RebootPending = $true
            Write-SetupLog -Level 'WARN' -Component $id -Message "pnputil pediu reinicio ao publicar $infName."
        }
        elseif ($exitCode -ne 0) {
            $attributed = Get-AttributedFailureExitCode -DefaultExitCode $script:InstallExitCodes[$id] -Stage 'instalacao'
            Exit-Setup -ExitCode $attributed `
                -Component $id `
                -Stage 'instalacao' `
                -Cause "pnputil /add-driver $infName retornou $exitCode" `
                -Action 'Verifique politicas de driver, antivirus e se a sessao e administrativa.'
        }

        $installed++
    }

    Write-SetupLog -Level 'INFO' -Component $id -Message "$installed arquivo(s) .inf publicados no DriverStore."
}

function Invoke-ScanPlugAndPlay {
    param([Parameter(Mandatory = $true)][string]$ComponentId)

    $scan = Start-ProcessWithTimeout `
        -FilePath "$env:SystemRoot\System32\pnputil.exe" `
        -Arguments @('/scan-devices') `
        -TimeoutSeconds 120 `
        -ComponentId $ComponentId

    if ($scan -ne 0 -and $scan -ne 3010) {
        Write-SetupLog -Level 'WARN' -Component $ComponentId -Message "pnputil /scan-devices retornou $scan. Desconecte e reconecte a interface USB."
    }
}

function Invoke-UnpublishLegacyKernel {
    param([Parameter(Mandatory = $true)]$Component)

    $id = [string]$Component.id
    $spec = Get-ObjectProperty -Object $Component -Name 'uninstall'
    if (-not $spec) { return }

    Write-SetupLog -Level 'INFO' -Component $id -Message 'Removendo o kernel 2.08.24 do DriverStore. O Windows 11 recusa carregar esse .sys (assinatura antiga / Integridade de memoria).'

    [void](Invoke-ComponentUninstall -ComponentId $id -UninstallSpec $spec)
    Invoke-ScanPlugAndPlay -ComponentId $id
}

function Install-DriverArchiveComponent {
    param([Parameter(Mandatory = $true)]$Component)

    $id = [string]$Component.id
    $timeout = [int](Get-ObjectProperty -Object $Component -Name 'timeoutSeconds')
    if ($timeout -le 0) { $timeout = 600 }

    if (Test-SkipLegacyKernelDriver -Component $Component) {
        $build = Get-OsBuildNumber
        $modernVersion = [string](Get-ObjectProperty -Object $Component -Name 'modernDriverVersion')
        if (-not $modernVersion) { $modernVersion = '2.12.36.20' }

        Write-SetupLog -Level 'WARN' -Component $id -Message "Windows build $build recusa o ftdibus.sys de 2012. O kit publica o CDM $modernVersion (WHQL) e continua copiando a ftd2xx.dll na etapa D2XX."
        Invoke-UnpublishLegacyKernel -Component $Component

        if (Test-ModernFtdiKernelPublished) {
            Write-SetupLog -Level 'INFO' -Component $id -Message 'Kernel FTDI 2.12+ ja esta no DriverStore; nada a publicar.'
            Invoke-ScanPlugAndPlay -ComponentId $id
            return
        }

        $driverDir = Get-ModernDriverPackageDirectory -Component $Component
        Publish-DriverInfFiles -Component $Component -DriverDir $driverDir
        Invoke-ScanPlugAndPlay -ComponentId $id
        return
    }

    $driverDir = Get-DriverPackageDirectory -Component $Component
    Publish-DriverInfFiles -Component $Component -DriverDir $driverDir
}

function Test-FtdiDeviceStatus {
    param([Parameter(Mandatory = $true)]$Component)

    $pnpDevices = @(Get-ObjectProperty -Object $Component -Name 'pnpDevices')
    if ($pnpDevices.Count -eq 0) { return }

    $id = [string]$Component.id

    foreach ($spec in $pnpDevices) {
        $hardwareId = [string](Get-ObjectProperty -Object $spec -Name 'hardwareId')
        if (-not $hardwareId) { continue }

        $optional = [bool](Get-ObjectProperty -Object $spec -Name 'optional')
        $devices = @(Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object {
            $_.InstanceId -like "*$hardwareId*" -or
            ($_.HardwareID -and (($_.HardwareID -join '|') -like "*$hardwareId*"))
        })

        if ($devices.Count -eq 0) {
            $message = "Nenhum dispositivo '$hardwareId' presente: interface USB nao conectada."
            if ($optional) {
                Write-SetupLog -Level 'WARN' -Component $id -Message "$message Nao e falha de instalacao."
            }
            else {
                Write-SetupLog -Level 'ERROR' -Component $id -Message $message
            }
            continue
        }

        foreach ($device in $devices) {
            Write-SetupLog -Level 'INFO' -Component $id -Message "PnP: $($device.FriendlyName) Status=$($device.Status) Problem=$($device.Problem)"

            if ($device.Status -ne 'Error') { continue }

            if ($device.Problem -eq 52) {
                $cause = 'Driver recusado por assinatura (Code 52)'
                if ($script:Inventory.SecureBootEnabled) { $cause += '; Secure Boot ativo' }
                if ($script:Inventory.HVCIEnabled) { $cause += '; HVCI ativo' }
                Exit-Setup -ExitCode 43 -Component $id -Stage 'validacao-pnp' -Cause $cause `
                    -Action 'No Windows 11 o kernel 2.08.24 e recusado. Rode o iniciar-kit.cmd desta versao (ele remove esse .sys) e reconecte a interface.'
            }

            if ($device.Problem -eq 28) {
                Write-SetupLog -Level 'WARN' -Component $id -Message "Dispositivo sem driver associado (Code 28). Desconecte e reconecte a interface USB para o Windows ligar no FTDI 2.12."
                continue
            }

            if ($device.Problem -eq 43) {
                Exit-Setup -ExitCode 44 -Component $id -Stage 'validacao-pnp' `
                    -Cause 'Falha de hardware ou driver (Code 43)' `
                    -Action 'Troque o cabo/porta USB e reinstale o driver.'
            }

            Write-SetupLog -Level 'WARN' -Component $id -Message "Dispositivo com erro nao classificado: Problem=$($device.Problem)"
        }
    }
}

#endregion

#region Instalacao do IOTerminal (portatil)

function Set-RunAsAdministratorFlag {
    param(
        [Parameter(Mandatory = $true)][string]$ExePath,
        [Parameter(Mandatory = $true)][string]$ComponentId
    )

    $subKey = 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers'
    $views = @([Microsoft.Win32.RegistryView]::Registry64, [Microsoft.Win32.RegistryView]::Registry32)
    $ok = 0

    foreach ($view in $views) {
        try {
            $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $view)
            $key = $base.CreateSubKey($subKey)
            $key.SetValue($ExePath, '~ RUNASADMIN', [Microsoft.Win32.RegistryValueKind]::String)
            $key.Dispose()
            $base.Dispose()
            $ok++
        }
        catch {
            Write-SetupLog -Level 'WARN' -Component $ComponentId -Message "Falha ao marcar RUNASADMIN ($view): $($_.Exception.Message)"
        }
    }

    if ($ok -gt 0) {
        Write-SetupLog -Level 'INFO' -Component $ComponentId -Message 'Executavel marcado para abrir sempre como administrador.'
    }
}

function New-DesktopShortcutForExe {
    param(
        [Parameter(Mandatory = $true)][string]$ExePath,
        [Parameter(Mandatory = $true)][string]$ShortcutName,
        [Parameter(Mandatory = $true)][string]$ComponentId
    )

    try {
        $desktop = [Environment]::GetFolderPath('CommonDesktopDirectory')
        $linkPath = Join-Path $desktop "$ShortcutName.lnk"
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($linkPath)
        $shortcut.TargetPath = $ExePath
        $shortcut.WorkingDirectory = Split-Path -Parent $ExePath
        $shortcut.Description = $ShortcutName
        $shortcut.Save()
        Write-SetupLog -Level 'INFO' -Component $ComponentId -Message "Atalho criado: $linkPath"
    }
    catch {
        Write-SetupLog -Level 'WARN' -Component $ComponentId -Message "Falha ao criar atalho: $($_.Exception.Message)"
    }
}

function Install-PortableArchiveComponent {
    param([Parameter(Mandatory = $true)]$Component)

    $id = [string]$Component.id
    $timeout = [int](Get-ObjectProperty -Object $Component -Name 'timeoutSeconds')
    if ($timeout -le 0) { $timeout = 900 }

    $installDir = Expand-PathToken -Value ([string](Get-ObjectProperty -Object $Component -Name 'installDir'))
    if (-not $installDir) {
        Exit-Setup -ExitCode 12 -Component $id -Stage 'manifesto' `
            -Cause 'Componente portatil sem installDir' -Action 'Defina installDir no manifest.json.'
    }

    $archive = Resolve-PackageItem -RelativePath ([string]$Component.archive) -ComponentId $id
    Test-PackageIntegrity -Path $archive -ExpectedSha256 ([string](Get-ObjectProperty -Object $Component -Name 'sha256')) -ComponentId $id

    $workDir = Initialize-WorkDirectory
    $extractDir = Join-Path $workDir "$id-extraido"
    Expand-ArchiveFile -ArchivePath $archive -Destination $extractDir -ComponentId $id -TimeoutSeconds $timeout | Out-Null

    $sourceRoot = Get-FlattenedRoot -Path $extractDir

    if (-not (Test-Path -LiteralPath $installDir)) {
        New-Item -ItemType Directory -Path $installDir -Force | Out-Null
    }

    Write-SetupLog -Level 'INFO' -Component $id -Message "Copiando aplicacao para $installDir"
    Copy-Item -Path (Join-Path $sourceRoot '*') -Destination $installDir -Recurse -Force

    $mainExe = [string](Get-ObjectProperty -Object $Component -Name 'mainExe')
    if ($mainExe) {
        $exePath = Join-Path $installDir $mainExe
        if (Test-Path -LiteralPath $exePath) {
            if ([bool](Get-ObjectProperty -Object $Component -Name 'runAsAdministrator')) {
                Set-RunAsAdministratorFlag -ExePath $exePath -ComponentId $id
            }
            if ([bool](Get-ObjectProperty -Object $Component -Name 'desktopShortcut')) {
                $shortcutName = [string](Get-ObjectProperty -Object $Component -Name 'displayName')
                if (-not $shortcutName) { $shortcutName = $id }
                New-DesktopShortcutForExe -ExePath $exePath -ShortcutName $shortcutName -ComponentId $id
            }
        }
        else {
            Write-SetupLog -Level 'WARN' -Component $id -Message "mainExe '$mainExe' nao encontrado apos a copia."
        }
    }
}

#endregion

#region Biblioteca D2XX

function Install-DllCopyComponent {
    param([Parameter(Mandatory = $true)]$Component)

    $id = [string]$Component.id

    $origemComponenteId = [string](Get-ObjectProperty -Object $Component -Name 'fromComponent')
    if (-not $origemComponenteId) {
        Exit-Setup -ExitCode 12 -Component $id -Stage 'manifesto' `
            -Cause 'Componente dll-copy sem fromComponent' `
            -Action 'Indique em fromComponent o id do componente que traz o pacote.'
    }

    $origem = @($script:Manifest.components | Where-Object { $_.id -eq $origemComponenteId }) | Select-Object -First 1
    if (-not $origem) {
        Exit-Setup -ExitCode 12 -Component $id -Stage 'manifesto' `
            -Cause "fromComponent '$origemComponenteId' nao existe no manifesto" `
            -Action 'Corrija o id em fromComponent.'
    }

    $pacoteDir = Get-DriverPackageDirectory -Component $origem

    $arquivos = @(Get-ObjectProperty -Object $Component -Name 'files')
    if ($arquivos.Count -eq 0) {
        Exit-Setup -ExitCode 12 -Component $id -Stage 'manifesto' `
            -Cause 'Componente dll-copy sem a lista files' `
            -Action 'Declare os pares source/target em files.'
    }

    foreach ($arquivo in $arquivos) {
        $relativo = [string](Get-ObjectProperty -Object $arquivo -Name 'source')
        $destino = Expand-PathToken -Value ([string](Get-ObjectProperty -Object $arquivo -Name 'target'))

        if (-not $relativo -or -not $destino) {
            Exit-Setup -ExitCode 12 -Component $id -Stage 'manifesto' `
                -Cause 'Item de files sem source ou target' -Action 'Corrija o manifest.json.'
        }

        $caminhoOrigem = Join-Path $pacoteDir $relativo
        if (-not (Test-Path -LiteralPath $caminhoOrigem -PathType Leaf)) {
            Exit-Setup -ExitCode 24 -Component $id -Stage 'extracao' `
                -Cause "Arquivo '$relativo' ausente no pacote extraido" `
                -Action 'Confira files no manifest.json e a integridade do pacote do driver.'
        }

        $pastaDestino = Split-Path -Parent $destino
        if (-not (Test-Path -LiteralPath $pastaDestino)) {
            $codigo = if ($script:InstallExitCodes.ContainsKey($id)) { $script:InstallExitCodes[$id] } else { 33 }
            Exit-Setup -ExitCode $codigo -Component $id -Stage 'instalacao' `
                -Cause "Pasta de destino ausente: $pastaDestino" `
                -Action 'O componente ioterminal precisa concluir antes da copia da DLL.'
        }

        # Em System32/SysWOW64, nao rebaixar uma D2XX ja presente (ex.: CDM 2.12).
        # Na pasta do IOT, a copia e nossa e pode ser refeita.
        $raizWindows = [IO.Path]::GetFullPath($env:SystemRoot).TrimEnd('\')
        $destinoCheio = [IO.Path]::GetFullPath($destino)
        $ehSistema = $destinoCheio.StartsWith($raizWindows + '\', [StringComparison]::OrdinalIgnoreCase)
        if ($ehSistema -and (Test-Path -LiteralPath $destino -PathType Leaf)) {
            $existente = (Get-Item -LiteralPath $destino).VersionInfo.FileVersion
            Write-SetupLog -Level 'INFO' -Component $id -Message "Preservado (ja existia v$existente): $destino"
            continue
        }

        Copy-Item -LiteralPath $caminhoOrigem -Destination $destino -Force

        $info = Get-Item -LiteralPath $destino
        $versao = if ($info.VersionInfo -and $info.VersionInfo.FileVersion) { $info.VersionInfo.FileVersion } else { 'sem versao' }
        Write-SetupLog -Level 'INFO' -Component $id -Message "$relativo -> $destino (v$versao)"
    }
}

#endregion

#region Copia da licenca

function Install-LicenseComponent {
    param([Parameter(Mandatory = $true)]$Component)

    $id = [string]$Component.id

    if (-not $script:InstallDir) {
        Exit-Setup -ExitCode 41 -Component $id -Stage 'licenca' `
            -Cause 'Pasta de instalacao do IOTerminal nao resolvida' `
            -Action 'Instale o componente ioterminal antes da licenca ou defina installDir no manifesto.'
    }

    if (-not (Test-Path -LiteralPath $script:InstallDir)) {
        Exit-Setup -ExitCode 41 -Component $id -Stage 'licenca' `
            -Cause "Pasta do IOTerminal ausente: $($script:InstallDir)" `
            -Action 'Rode a instalacao completa (o componente ioterminal precisa concluir antes).'
    }

    $source = Resolve-PackageItem -RelativePath ([string]$Component.source) -ComponentId $id
    $targetSubDir = [string](Get-ObjectProperty -Object $Component -Name 'targetSubDir')
    if (-not $targetSubDir) { $targetSubDir = Split-Path -Leaf $source }

    $target = Join-Path $script:InstallDir $targetSubDir

    if (Test-Path -LiteralPath $target) {
        $backup = "$target.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Write-SetupLog -Level 'WARN' -Component $id -Message "Licenca existente preservada em: $backup"
        Move-Item -LiteralPath $target -Destination $backup -Force
    }

    New-Item -ItemType Directory -Path $target -Force | Out-Null
    Copy-Item -Path (Join-Path $source '*') -Destination $target -Recurse -Force

    $copied = @(Get-ChildItem -LiteralPath $target -File -Recurse -ErrorAction SilentlyContinue)
    Write-SetupLog -Level 'INFO' -Component $id -Message "Licenca copiada para $target ($($copied.Count) arquivo(s))."
}

#endregion

#region Rollback

function Get-PublishedDriverNames {
    param(
        [Parameter(Mandatory = $true)][string]$OriginalName,
        [Parameter(Mandatory = $false)][string]$DriverVersion,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[string]]$Result
    )

    $blocks = New-Object 'System.Collections.Generic.List[string]'
    Get-PublishedDriverBlocks -OriginalName $OriginalName -DriverVersion $DriverVersion -Result $blocks

    foreach ($block in $blocks) {
        foreach ($match in [regex]::Matches($block, '(?i)oem\d+\.inf')) {
            $nome = $match.Value.ToLowerInvariant()
            if (-not $Result.Contains($nome)) { $Result.Add($nome) }
        }
    }
}

function Invoke-ComponentUninstall {
    param(
        [Parameter(Mandatory = $true)][string]$ComponentId,
        [Parameter(Mandatory = $true)]$UninstallSpec
    )

    if ($null -eq $UninstallSpec) {
        Write-SetupLog -Level 'WARN' -Component $ComponentId -Message 'Metodo de desinstalacao nao definido: componente preservado.'
        return $false
    }

    $kind = [string](Get-ObjectProperty -Object $UninstallSpec -Name 'kind')

    if ($kind -eq 'driver') {
        $originalNames = @(Get-ObjectProperty -Object $UninstallSpec -Name 'originalNames' | Where-Object { $_ })
        if (@($originalNames).Count -eq 0) { return $false }

        $driverVersion = [string](Get-ObjectProperty -Object $UninstallSpec -Name 'driverVersion')

        $failures = 0
        foreach ($originalName in $originalNames) {
            $publishedNames = New-Object 'System.Collections.Generic.List[string]'
            Get-PublishedDriverNames -OriginalName ([string]$originalName) -DriverVersion $driverVersion -Result $publishedNames

            if ($publishedNames.Count -eq 0) {
                Write-SetupLog -Level 'INFO' -Component $ComponentId -Message "Driver '$originalName' nao esta publicado; nada a remover."
                continue
            }

            foreach ($publishedName in $publishedNames) {
                $exitCode = Start-ProcessWithTimeout `
                    -FilePath "$env:SystemRoot\System32\pnputil.exe" `
                    -Arguments @('/delete-driver', $publishedName, '/uninstall', '/force') `
                    -TimeoutSeconds 300 `
                    -ComponentId $ComponentId

                if ($exitCode -eq 3010) {
                    $script:RebootPending = $true
                }
                elseif ($exitCode -ne 0) {
                    $failures++
                    Write-SetupLog -Level 'ERROR' -Component $ComponentId -Message "pnputil /delete-driver $publishedName retornou $exitCode."
                }
            }
        }

        return ($failures -eq 0)
    }

    if ($kind -eq 'remove-file') {
        $paths = @(Get-ObjectProperty -Object $UninstallSpec -Name 'paths')
        if ($paths.Count -eq 0) { return $false }

        $failures = 0
        foreach ($path in $paths) {
            $caminho = Expand-PathToken -Value ([string]$path)
            if (-not $caminho) { continue }

            if (-not (Test-Path -LiteralPath $caminho)) {
                Write-SetupLog -Level 'INFO' -Component $ComponentId -Message "Arquivo ja ausente: $caminho"
                continue
            }

            try {
                Remove-Item -LiteralPath $caminho -Force -ErrorAction Stop
                Write-SetupLog -Level 'INFO' -Component $ComponentId -Message "Arquivo removido: $caminho"
            }
            catch {
                $failures++
                Write-SetupLog -Level 'ERROR' -Component $ComponentId -Message "Falha ao remover ${caminho}: $($_.Exception.Message)"
            }
        }

        return ($failures -eq 0)
    }

    if ($kind -eq 'remove-dir') {
        $path = Expand-PathToken -Value ([string](Get-ObjectProperty -Object $UninstallSpec -Name 'path'))
        if (-not $path) { return $false }

        if (-not (Test-Path -LiteralPath $path)) {
            Write-SetupLog -Level 'INFO' -Component $ComponentId -Message "Pasta ja ausente: $path"
            return $true
        }

        try {
            Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
            Write-SetupLog -Level 'INFO' -Component $ComponentId -Message "Pasta removida: $path"
            return $true
        }
        catch {
            Write-SetupLog -Level 'ERROR' -Component $ComponentId -Message "Falha ao remover ${path}: $($_.Exception.Message)"
            return $false
        }
    }

    Write-SetupLog -Level 'WARN' -Component $ComponentId -Message "Tipo de desinstalacao desconhecido: $kind"
    return $false
}

function Invoke-Rollback {
    param([Parameter(Mandatory = $true)]$Manifest)

    Write-SetupLog -Level 'INFO' -Component 'ROLLBACK' -Message 'Iniciando reversao...'

    $state = Get-SetupState
    $entries = @($state.components | Where-Object { $_ })
    if ($entries.Count -eq 0) {
        Write-SetupLog -Level 'INFO' -Component 'ROLLBACK' -Message 'Nenhum componente registrado em state.json.'
        return 0
    }

    $ordered = @($entries | Sort-Object {
        $entryId = $_.id
        $comp = @($Manifest.components | Where-Object { $_.id -eq $entryId }) | Select-Object -First 1
        if ($comp) { [int]$comp.order } else { 0 }
    } -Descending)

    $failures = 0
    foreach ($entry in $ordered) {
        $entryId = [string]$entry.id

        if (-not $entry.installedByTool) {
            Write-SetupLog -Level 'INFO' -Component $entryId -Message 'Ignorado no rollback (nao instalado por esta ferramenta).'
            continue
        }

        $manifestComp = @($Manifest.components | Where-Object { $_.id -eq $entryId }) | Select-Object -First 1
        $spec = Get-ObjectProperty -Object $entry -Name 'uninstall'
        if (-not $spec -and $manifestComp) {
            $spec = Get-ObjectProperty -Object $manifestComp -Name 'uninstall'
        }

        if (Invoke-ComponentUninstall -ComponentId $entryId -UninstallSpec $spec) {
            Remove-ComponentFromState -ComponentId $entryId
            Write-SetupLog -Level 'INFO' -Component $entryId -Message 'Reversao concluida.'
        }
        else {
            $failures++
        }
    }

    if ($failures -gt 0) {
        Write-SetupLog -Level 'ERROR' -Component 'ROLLBACK' -Message "$failures componente(s) falharam na reversao."
        return 1
    }

    Write-SetupLog -Level 'INFO' -Component 'ROLLBACK' -Message 'Reversao concluida com sucesso.'
    return 0
}

function Test-InstallDirIsSafeToRemove {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not $Path) { return $false }

    $cheio = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if ($cheio -match '^[A-Za-z]:\\?$') { return $false }

    $proibidos = @(
        $env:SystemRoot,
        $env:ProgramFiles,
        ${env:ProgramFiles(x86)},
        $env:SystemDrive + '\Users'
    ) | Where-Object { $_ }

    foreach ($proibido in $proibidos) {
        $base = [IO.Path]::GetFullPath($proibido).TrimEnd('\')
        if ($cheio.Equals($base, [StringComparison]::OrdinalIgnoreCase)) { return $false }
    }

    return $true
}

function Stop-InstallDirProcesses {
    param(
        [Parameter(Mandatory = $true)][string]$InstallDir,
        [Parameter(Mandatory = $true)][string]$ComponentId
    )

    $raiz = [IO.Path]::GetFullPath($InstallDir).TrimEnd('\')
    $encerrados = 0

    $processos = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
        try {
            if (-not $_.Path) { return $false }
            $caminho = [IO.Path]::GetFullPath($_.Path)
            return $caminho.StartsWith($raiz + '\', [StringComparison]::OrdinalIgnoreCase) -or
                   $caminho.Equals($raiz, [StringComparison]::OrdinalIgnoreCase)
        }
        catch {
            return $false
        }
    })

    $porNome = @(Get-Process -Name 'iot_MULTITOOLv50B' -ErrorAction SilentlyContinue)
    $todos = @($processos + $porNome | Sort-Object Id -Unique)

    foreach ($proc in $todos) {
        Write-SetupLog -Level 'INFO' -Component $ComponentId -Message "Encerrando PID $($proc.Id) ($($proc.ProcessName))"
        try {
            Stop-Process -Id $proc.Id -Force -ErrorAction Stop
            $encerrados++
        }
        catch {
            Write-SetupLog -Level 'WARN' -Component $ComponentId -Message "Nao foi possivel encerrar PID $($proc.Id): $($_.Exception.Message)"
        }
    }

    if ($encerrados -gt 0) {
        Start-Sleep -Seconds 2
    }
}

function Remove-DesktopShortcutForIoTerminal {
    param([Parameter(Mandatory = $true)]$Manifest)

    $component = @($Manifest.components | Where-Object { $_.id -eq 'ioterminal' }) | Select-Object -First 1
    $nome = if ($component) { [string](Get-ObjectProperty -Object $component -Name 'displayName') } else { '' }
    if (-not $nome) { $nome = 'IOT Multitool V50B' }

    $pastas = @(
        [Environment]::GetFolderPath('CommonDesktopDirectory'),
        [Environment]::GetFolderPath('Desktop')
    ) | Where-Object { $_ }

    foreach ($pasta in $pastas) {
        $atalho = Join-Path $pasta "$nome.lnk"
        if (Test-Path -LiteralPath $atalho) {
            Remove-Item -LiteralPath $atalho -Force -ErrorAction SilentlyContinue
            Write-SetupLog -Level 'INFO' -Component 'ioterminal' -Message "Atalho removido: $atalho"
        }
    }
}

function Invoke-ReinstallCleanup {
    param([Parameter(Mandatory = $true)]$Manifest)

    Write-SetupLog -Level 'INFO' -Component 'REINSTALL' -Message 'Removendo instalacao anterior do IOTerminal...'

    if (-not $script:InstallDir) {
        Write-SetupLog -Level 'INFO' -Component 'REINSTALL' -Message 'Pasta de instalacao nao resolvida: nada a remover.'
        return
    }

    if (-not (Test-InstallDirIsSafeToRemove -Path $script:InstallDir)) {
        Exit-Setup -ExitCode 11 -Component 'REINSTALL' -Stage 'reinstalacao' `
            -Cause "installDir recusado para remocao: $($script:InstallDir)" `
            -Action 'Corrija installDir no manifest.json.'
    }

    Stop-InstallDirProcesses -InstallDir $script:InstallDir -ComponentId 'REINSTALL'

    if (Test-Path -LiteralPath $script:InstallDir) {
        try {
            Remove-Item -LiteralPath $script:InstallDir -Recurse -Force -ErrorAction Stop
            Write-SetupLog -Level 'INFO' -Component 'REINSTALL' -Message "Pasta removida: $($script:InstallDir)"
        }
        catch {
            Exit-Setup -ExitCode 31 -Component 'REINSTALL' -Stage 'reinstalacao' `
                -Cause "Nao foi possivel apagar $($script:InstallDir): $($_.Exception.Message)" `
                -Action 'Feche o IOT Multitool e o aviso do Themida, depois rode o iniciar-kit.cmd de novo.'
        }
    }
    else {
        Write-SetupLog -Level 'INFO' -Component 'REINSTALL' -Message "Pasta ja ausente: $($script:InstallDir)"
    }

    Remove-DesktopShortcutForIoTerminal -Manifest $Manifest

    $driver = @($Manifest.components | Where-Object { $_.id -eq 'driver_cdm20824' }) | Select-Object -First 1
    if ($driver) {
        Invoke-UnpublishLegacyKernel -Component $driver
        Remove-ComponentFromState -ComponentId 'driver_cdm20824'
    }

    foreach ($id in @('ioterminal', 'd2xx_runtime', 'license_idmonact')) {
        Remove-ComponentFromState -ComponentId $id
    }

    Write-SetupLog -Level 'INFO' -Component 'REINSTALL' -Message 'Limpeza concluida. O kernel 2.08.24 foi retirado do DriverStore; o FTDI do Windows permanece.'
}

#endregion

#region DryRun

function Write-DryRunReport {
    param(
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)]$Components,
        [Parameter(Mandatory = $false)][string[]]$TodoFields = @()
    )

    Write-SetupLog -Level 'INFO' -Component 'DRYRUN' -Message '=== RELATORIO DRY-RUN ==='
    Write-SetupLog -Level 'INFO' -Component 'DRYRUN' -Message "Versao do pacote: $($Manifest.packageVersion)"
    Write-SetupLog -Level 'INFO' -Component 'DRYRUN' -Message "Pasta de pacotes: $($script:PackagesRoot)"
    Write-SetupLog -Level 'INFO' -Component 'DRYRUN' -Message "Pasta de instalacao do IOTerminal: $($script:InstallDir)"

    $tool = Get-ArchiveTool
    if ($tool) {
        Write-SetupLog -Level 'INFO' -Component 'DRYRUN' -Message "Extrator disponivel: $($tool.kind) ($($tool.path))"
    }
    else {
        Write-SetupLog -Level 'WARN' -Component 'DRYRUN' -Message 'Nenhum extrator de .rar encontrado: instale o 7-Zip antes da execucao real.'
    }

    foreach ($component in $Components) {
        $id = [string]$component.id
        Write-SetupLog -Level 'INFO' -Component 'DRYRUN' -Message "[$($component.order)] $id - $($component.displayName) (kind=$($component.kind))"

        foreach ($field in @('archive', 'source')) {
            $value = [string](Get-ObjectProperty -Object $component -Name $field)
            if (-not $value) { continue }

            $path = if ([IO.Path]::IsPathRooted($value)) { $value } else { Join-Path $script:PackagesRoot $value }
            Write-SetupLog -Level 'INFO' -Component $id -Message "$field presente: $(Test-Path -LiteralPath $path) ($path)"
        }

        $detect = Test-ComponentDetect -Component $component
        Write-SetupLog -Level 'INFO' -Component $id -Message "detect pre-execucao: $(if ($detect) { 'INSTALADO (seria SKIPPED)' } else { 'AUSENTE (seria INSTALADO)' })"
    }

    if ($TodoFields.Count -gt 0) {
        Write-SetupLog -Level 'WARN' -Component 'DRYRUN' -Message "Campos TODO pendentes ($($TodoFields.Count)):"
        foreach ($field in ($TodoFields | Sort-Object -Unique)) {
            Write-SetupLog -Level 'WARN' -Component 'DRYRUN' -Message "  - $field"
        }
    }
    else {
        Write-SetupLog -Level 'INFO' -Component 'DRYRUN' -Message 'Nenhum campo TODO no manifesto.'
    }

    Write-SetupLog -Level 'INFO' -Component 'DRYRUN' -Message '=== FIM DO DRY-RUN (nenhuma alteracao realizada) ==='
}

#endregion

#region Fluxo de instalacao

function Install-Component {
    param([Parameter(Mandatory = $true)]$Component)

    switch ([string]$Component.kind) {
        'driver-archive'   { Install-DriverArchiveComponent -Component $Component }
        'portable-archive' { Install-PortableArchiveComponent -Component $Component }
        'dll-copy'         { Install-DllCopyComponent -Component $Component }
        'license-copy'     { Install-LicenseComponent -Component $Component }
        default {
            Exit-Setup -ExitCode 12 -Component ([string]$Component.id) -Stage 'manifesto' `
                -Cause "kind sem implementacao: $($Component.kind)" -Action 'Corrija o manifest.json.'
        }
    }
}

function Invoke-InstallFlow {
    param(
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)]$Components
    )

    $exclusions = @($script:PackagesRoot, $script:SetupDataDir, $env:TEMP, $script:InstallDir)
    Add-AntivirusExclusions -Paths $exclusions

    $summary = @()

    foreach ($component in $Components) {
        $id = [string]$component.id
        Write-SetupLog -Level 'INFO' -Component $id -Message '--- Iniciando componente ---'

        if ((Test-ComponentDetect -Component $component) -and -not $Force) {
            Write-SetupLog -Level 'INFO' -Component $id -Message 'SKIPPED - detect indica instalacao preexistente.'
            $summary += @{ id = $id; action = 'SKIPPED' }

            if (-not (Test-ComponentValidate -Component $component)) {
                Exit-Setup -ExitCode $script:ValidateExitCodes[$id] `
                    -Component $id `
                    -Stage 'validacao' `
                    -Cause 'Componente detectado mas validate falhou' `
                    -Action 'Execute novamente com -Force para reinstalar este componente.'
            }

            continue
        }

        Install-Component -Component $component

        if (-not (Test-ComponentValidate -Component $component)) {
            Exit-Setup -ExitCode $script:ValidateExitCodes[$id] `
                -Component $id `
                -Stage 'validacao' `
                -Cause 'Predicados validate falharam apos a instalacao' `
                -Action 'Consulte as linhas validate no log para ver qual caminho ficou ausente.'
        }

        Update-ComponentState `
            -ComponentId $id `
            -PackageVersion ([string]$Manifest.packageVersion) `
            -InstalledByTool $true `
            -UninstallInfo (ConvertTo-HashtableRecursive -InputObject (Get-ObjectProperty -Object $component -Name 'uninstall')) `
            -InstallDir $script:InstallDir

        if ([string]$component.kind -eq 'driver-archive') {
            Test-FtdiDeviceStatus -Component $component
        }

        $summary += @{ id = $id; action = 'INSTALLED' }
        Write-SetupLog -Level 'INFO' -Component $id -Message 'Componente concluido com sucesso.'
    }

    Write-SetupLog -Level 'INFO' -Message '=== SUMARIO ==='
    foreach ($item in $summary) {
        Write-SetupLog -Level 'INFO' -Component $item.id -Message $item.action
    }

    if ($script:RebootPending) {
        Write-SetupLog -Level 'WARN' -Message 'Reinicio pendente: reinicie a maquina manualmente.'
        return 3010
    }

    return 0
}

function Resolve-InstallDir {
    param([Parameter(Mandatory = $true)]$Manifest)

    $component = @($Manifest.components | Where-Object { $_.id -eq 'ioterminal' }) | Select-Object -First 1
    if ($component) {
        $dir = [string](Get-ObjectProperty -Object $component -Name 'installDir')
        if ($dir) { return $dir }
    }

    return Get-StateInstallDir
}

#endregion

#region Ponto de entrada

$exitCode = 1

try {
    Start-SetupLogging

    if ($DryRun -and ($Rollback -or $Force -or $Reinstall)) {
        Exit-Setup -ExitCode 11 -Stage 'parametros' `
            -Cause '-DryRun nao combina com -Rollback, -Force nem -Reinstall' `
            -Action 'Execute um modo por vez.'
    }

    if ($Rollback -and $Reinstall) {
        Exit-Setup -ExitCode 11 -Stage 'parametros' `
            -Cause '-Rollback nao combina com -Reinstall' `
            -Action 'Use -Reinstall para apagar o IOT e instalar de novo, ou -Rollback para so reverter.'
    }

    $script:KitRoot = Get-SetupKitRoot
    if (-not $ManifestPath) {
        $ManifestPath = Join-Path $script:KitRoot 'manifest.json'
    }

    Write-SetupLog -Level 'INFO' -Message "Revisao do kit: $($script:KitRevision)"
    Write-SetupLog -Level 'INFO' -Message "Kit root: $($script:KitRoot)"
    Write-SetupLog -Level 'INFO' -Message "Manifesto: $ManifestPath"
    Write-SetupLog -Level 'INFO' -Message "Modo: DryRun=$DryRun Rollback=$Rollback Force=$Force Reinstall=$Reinstall"

    if (-not (Test-IsAdministrator)) {
        Exit-Setup -ExitCode 10 -Stage 'privilegio' `
            -Cause 'Processo sem privilegio administrativo' `
            -Action 'Use scripts\iniciar-kit.cmd ou abra o PowerShell como administrador.'
    }

    $script:Inventory = Get-EnvironmentInventory
    $script:Manifest = Get-ManifestContent -Path $ManifestPath
    Test-ManifestStructure -Manifest $script:Manifest
    Test-EnvironmentPreconditions -Manifest $script:Manifest

    $script:PackagesRoot = Get-PackagesRoot -Manifest $script:Manifest
    $script:InstallDir = Resolve-InstallDir -Manifest $script:Manifest
    Write-SetupLog -Level 'INFO' -Message "Pasta de pacotes: $($script:PackagesRoot)"
    Write-SetupLog -Level 'INFO' -Message "Pasta do IOTerminal: $($script:InstallDir)"

    $components = @($script:Manifest.components | Sort-Object { [int]$_.order }, { $_.id })
    $todoFields = @(Get-ManifestTodoFields -Object $script:Manifest)

    if ($DryRun) {
        Write-DryRunReport -Manifest $script:Manifest -Components $components -TodoFields $todoFields
        $exitCode = 0
    }
    elseif ($todoFields.Count -gt 0) {
        Write-SetupLog -Level 'ERROR' -Component 'MANIFEST' -Message "Manifesto contem $($todoFields.Count) campo(s) TODO:"
        foreach ($field in ($todoFields | Sort-Object -Unique)) {
            Write-SetupLog -Level 'ERROR' -Component 'MANIFEST' -Message "  - $field"
        }
        Exit-Setup -ExitCode 12 -Stage 'manifesto' `
            -Cause 'Manifesto com campos TODO nao preenchidos' `
            -Action 'Complete o manifest.json ou rode -DryRun para listar as lacunas.'
    }
    elseif ($Rollback) {
        $exitCode = Invoke-Rollback -Manifest $script:Manifest
    }
    else {
        if ($Reinstall) {
            Invoke-ReinstallCleanup -Manifest $script:Manifest
        }
        $exitCode = Invoke-InstallFlow -Manifest $script:Manifest -Components $components
    }

    if ($exitCode -eq 0) {
        Write-SetupLog -Level 'INFO' -Message 'Execucao finalizada com sucesso.'
    }
}
catch {
    Write-SetupLog -Level 'ERROR' -Message "Erro inesperado: $($_.Exception.Message)"
    Write-SetupLog -Level 'ERROR' -Message $_.ScriptStackTrace
    $exitCode = 1
}
finally {
    Stop-SetupLogging
}

exit $exitCode

#endregion
