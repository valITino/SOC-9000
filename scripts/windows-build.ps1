[CmdletBinding()]
param(
    [string]$IsoWindows,
    [string]$WindowsOut,
    [string]$LogW,
    [string]$Wtpl,
    [string]$PackerExe,
    [string]$IsoChecksum,
    [int]$WindowsMaxMinutes = 120
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Initialize script-scoped variables for Show-Stage function
$script:_lastTail = ''
$script:_lastTailAt = Get-Date 0

# Helper functions
function Write-Info([string]$m){ Write-Host "[> ] $m" -ForegroundColor Cyan }
function Write-Ok([string]$m){ Write-Host "[OK] $m" -ForegroundColor Green }
function Write-Warn([string]$m){ Write-Host "[!] $m" -ForegroundColor Yellow }
function Write-Fail([string]$m){ Write-Host "[X]  $m" -ForegroundColor Red }

function Get-RepoRoot { 
    # Try multiple methods to get the script directory
    $scriptDir = $null
    if ($PSScriptRoot) {
        $scriptDir = $PSScriptRoot
    } elseif ($MyInvocation.MyCommand.Path) {
        $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    } elseif ($PSCommandPath) {
        $scriptDir = Split-Path -Parent $PSCommandPath
    } else {
        $scriptDir = (Get-Location).Path
    }
    
    # Resolve the repo root (one level up from scripts directory)
    (Resolve-Path (Join-Path $scriptDir '..')).Path 
}

function Find-Iso([string]$dir,[string[]]$patterns){
    if(!(Test-Path -LiteralPath $dir)){ return $null }
    $cands = foreach($pat in $patterns){ Get-ChildItem -LiteralPath $dir -Filter $pat -ErrorAction SilentlyContinue }
    $cands | Sort-Object LastWriteTime -Descending | Select-Object -First 1
}

function Find-PackerExe {
    $cmd = Get-Command packer -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Path) { return $cmd.Path }

    $cands = @()
    if ($env:LOCALAPPDATA) {
        $cands += (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\packer.exe')
        $cands += (Join-Path $env:LOCALAPPDATA 'HashiCorp\Packer\packer.exe')
    }
    if ($env:ProgramFiles)        { $cands += (Join-Path $env:ProgramFiles        'HashiCorp\Packer\packer.exe') }
    if (${env:ProgramFiles(x86)}) { $cands += (Join-Path ${env:ProgramFiles(x86)} 'HashiCorp\Packer\packer.exe') }
    if ($env:ChocolateyInstall)   { $cands += (Join-Path $env:ChocolateyInstall   'bin\packer.exe') }
    $cands += 'C:\ProgramData\chocolatey\bin\packer.exe'

    foreach ($p in $cands | Where-Object { $_ }) {
        try { if (Test-Path -LiteralPath $p) { return (Resolve-Path -LiteralPath $p).Path } } catch {}
    }

    $roots = @()
    if ($env:LOCALAPPDATA) {
        $roots += (Join-Path $env:LOCALAPPDATA 'HashiCorp')
        $roots += (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages')
    }
    if ($env:ProgramFiles) { $roots += (Join-Path $env:ProgramFiles 'HashiCorp') }

    foreach ($r in $roots | Where-Object { $_ -and (Test-Path $_) }) {
        try {
            $found = Get-ChildItem -Path $r -Filter 'packer.exe' -Recurse -ErrorAction SilentlyContinue |
                   Select-Object -First 1 -ExpandProperty FullName
            if ($found) { return $found }
        } catch {}
    }
    return $null
}

function Get-DotEnv([string]$Path){
    $m = @{}
    if (!(Test-Path -LiteralPath $Path)) { return $m }
    Get-Content -LiteralPath $Path | ForEach-Object {
        if ($_ -match '^\s*#' -or $_ -match '^\s*$') { return }
        if ($_ -match '^([^=]+)=(.*)$') {
            $k = $matches[1].Trim()
            $v = $matches[2].Trim()
            if ($k) { $m[$k] = $v }
        }
    }
    return $m
}

function New-Directory([string]$path){
    if (-not $path) { return }
    if (-not (Test-Path -LiteralPath $path)) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }
}

function Assert-Exists([string]$p,[string]$label){
    if(!(Test-Path -LiteralPath $p)){ throw "$label not found: $p" }
}

function Show-Stage([string]$log,[datetime]$start,[int]$max){
    $stages = @(
        @{N='Booting ISO';         P='(boot|Starting HTTP|vmware-iso: VM)'},
        @{N='Waiting for SSH';     P='Waiting for SSH'},
        @{N='Connected via SSH';   P='Connected to SSH|SSH handshake'},
        @{N='Provisioning';        P='Provisioning|Uploading|Executing'},
        @{N='Shutdown';            P='Gracefully|Stopping|Powering off'},
        @{N='Artifact complete';   P='Builds finished|Artifact'}
    )
    $text = ''
    if (Test-Path -LiteralPath $log) {
        $text = ((Get-Content -LiteralPath $log -Tail 200 -ErrorAction SilentlyContinue) -join "`n")
    }
    $done = 0; foreach($s in $stages){ if($text -match $s.P){ $done++ } }
    $pct = [int](($done / $stages.Count) * 100)
    $elapsed = (Get-Date)-$start
    $limit=[TimeSpan]::FromMinutes($max)
    Write-Progress -Activity "Packer build" -Status ("Elapsed {0:hh\:mm\:ss} / {1:hh\:mm}" -f $elapsed,$limit) -PercentComplete $pct

    if ($text) {
        $last  = ((($text -split "`n") | Select-Object -Last 10) -join "`n")
        $since = ((Get-Date) - $script:_lastTailAt).TotalSeconds
        if ($last -ne $script:_lastTail -and $since -ge 20) {
            Write-Host "`n--- packer tail ---`n$last`n--------------------"
            $script:_lastTail   = $last
            $script:_lastTailAt = Get-Date
        }
    }
}

function Invoke-PackerInit([string]$tpl,[string]$log){
    $tplDir  = [System.IO.Path]::GetDirectoryName($tpl)
    $tplLeaf = [System.IO.Path]::GetFileName($tpl)
    $args    = @('init', $tplLeaf)
    Write-Info ("RUN: init {0}" -f $tpl)
    Push-Location $tplDir
    try {
        & $PackerExe @args 2>&1 | Tee-Object -FilePath $log -Append
        if ($LASTEXITCODE -ne 0) {
            $tail = (Test-Path $log) ? ((Get-Content $log -Tail 60) -join "`n") : ''
            throw "packer init failed ($LASTEXITCODE) :: $tpl`n--- last lines ---`n$tail"
        }
    } finally { Pop-Location }
}

function Invoke-PackerValidate([string]$tpl,[string]$log,[hashtable]$vars){
    $tplDir  = [System.IO.Path]::GetDirectoryName($tpl)
    $tplLeaf = [System.IO.Path]::GetFileName($tpl)
    $args    = @('validate')
    foreach($k in $vars.Keys){ $args += @('-var',("{0}={1}" -f $k,$vars[$k])) }
    $args += $tplLeaf
    Write-Info ("RUN: validate {0}" -f $tpl)
    Push-Location $tplDir
    try {
        & $PackerExe @args 2>&1 | Tee-Object -FilePath $log -Append
        if ($LASTEXITCODE -ne 0) {
            $tail = (Test-Path $log) ? ((Get-Content $log -Tail 60) -join "`n") : ''
            throw "packer validate failed ($LASTEXITCODE) :: $tpl`n--- last lines ---`n$tail"
        }
    } finally { Pop-Location }
}

function Invoke-PackerBuild([string]$tpl,[string]$log,[hashtable]$vars,[int]$maxMinutes){
    $env:PACKER_LOG      = '1'
    $env:PACKER_LOG_PATH = $log

    $tplDir  = [System.IO.Path]::GetDirectoryName($tpl)
    $tplLeaf = [System.IO.Path]::GetFileName($tpl)

    $args = @('build','-timestamp-ui','-force')
    foreach($k in $vars.Keys){ $args += @('-var',("{0}={1}" -f $k,$vars[$k])) }
    $args += $tplLeaf

    # PS 5.1: -ArgumentList must be ONE string
    $argStr = ($args | ForEach-Object {
        if ($_ -match '[\s"`]') { '"' + ($_ -replace '"','\"') + '"' } else { $_ }
    }) -join ' '

    Write-Info ("RUN: build {0}" -f $tpl)
    $p = Start-Process -FilePath $PackerExe -ArgumentList $argStr -PassThru -WorkingDirectory $tplDir

    $start = Get-Date
    while (-not $p.HasExited) {
        Show-Stage -log $log -start $start -max $maxMinutes
        if (((Get-Date) - $start).TotalMinutes -ge $maxMinutes) {
            try { Stop-Process -Id $p.Id -Force } catch {}
            throw "Timeout after $maxMinutes min (log: $log)"
        }
        Start-Sleep -Seconds 5
        try { $p.Refresh() } catch {}
    }
    if ($p.ExitCode -ne 0) {
        $tail = ''
        if (Test-Path -LiteralPath $log) {
            $tail = ((Get-Content -LiteralPath $log -Tail 200 -ErrorAction SilentlyContinue) -join "`n")
        }
        if ($tail -match '(?i)build was cancelled|received interrupt') {
            Write-Warn "Packer reported a cancellation. Auto-retrying once in 10s (log: $log)..."
            Start-Sleep -Seconds 10
            return Invoke-PackerBuild $tpl $log $vars $maxMinutes
        }
        throw "packer build failed ($($p.ExitCode)) (log: $log)`n--- last lines ---`n$tail"
    }
    Write-Progress -Activity "Packer build" -Completed
    Write-Ok ("Build OK (log: {0})" -f $log)
}

# Main Windows build execution
try {
    # If running directly, set up the environment
    if ([string]::IsNullOrEmpty($IsoWindows) -or 
        [string]::IsNullOrEmpty($WindowsOut) -or 
        [string]::IsNullOrEmpty($LogW) -or 
        [string]::IsNullOrEmpty($Wtpl) -or 
        [string]::IsNullOrEmpty($PackerExe)) {
        
        Write-Info "Running in standalone mode, setting up environment..."
        
        # Get repo root
        Write-Info "Getting repository root..."
        $RepoRoot = Get-RepoRoot
        Write-Info "Repository root: $RepoRoot"
        Set-Location $RepoRoot
        
        # Load environment file
        Write-Info "Loading environment file..."
        $EnvFile = Join-Path $RepoRoot '.env'
        Write-Info "Environment file: $EnvFile"
        $envMap = Get-DotEnv $EnvFile
        
        # Set install root
        Write-Info "Setting install root..."
        $InstallRoot = $envMap['INSTALL_ROOT']
        if (-not $InstallRoot) {
            if (Test-Path 'E:\') { $InstallRoot = 'E:\SOC-9000-Install' }
            else { $InstallRoot = (Join-Path $env:SystemDrive 'SOC-9000-Install') }
        }
        Write-Info "Install root: $InstallRoot"
                
        # Set ISO root
        $IsoRoot = $envMap['ISO_DIR']
        if (-not $IsoRoot) { $IsoRoot = Join-Path $InstallRoot 'isos' }
        New-Directory $IsoRoot
        
        # Find Windows ISO
        if ([string]::IsNullOrEmpty($IsoWindows)) {
            $w = Find-Iso $IsoRoot @('Win*11*.iso','Windows*11*.iso','en-us_windows_11*.iso')
            if ($w) { 
                $IsoWindows = $w.FullName
                Write-Info "Found Windows ISO: $IsoWindows"
            } else {
                throw "Windows 11 ISO not found in $IsoRoot. Please place a Windows 11 ISO in the ISO directory."
            }
        }
        
        # Set Windows output directory
        if ([string]::IsNullOrEmpty($WindowsOut)) {
            $VmRoot = Join-Path $InstallRoot 'VMs'
            $WindowsOut = Join-Path $VmRoot 'Windows'
            New-Directory $WindowsOut
        }
        
        # Set log directory and create log file
        if ([string]::IsNullOrEmpty($LogW)) {
            $LogDir = Join-Path $InstallRoot 'logs\packer'
            New-Directory $LogDir
            $timestamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
            $LogW = Join-Path $LogDir ("windows-{0}.log" -f $timestamp)
        }
        
        # Find Packer executable
        if ([string]::IsNullOrEmpty($PackerExe)) {
            $PackerExe = Find-PackerExe
            if (-not $PackerExe) {
                throw "Packer executable not found. Please install Packer."
            }
        }
        
        # Find Windows template
        if ([string]::IsNullOrEmpty($Wtpl)) {
            $Wtpl = Join-Path $RepoRoot 'packer\windows-victim\windows.pkr.hcl'
            Assert-Exists $Wtpl 'Windows Packer template'
        }
    }
    
    # Check if ISO file exists
    if (-not (Test-Path -LiteralPath $IsoWindows)) {
        throw "Windows 11 ISO not found at: $IsoWindows. Please download the Windows 11 ISO and place it in the ISO directory."
    }
    
    Write-Info ("Windows build log: {0}" -f $LogW)

    $varsW = @{
        iso_path   = $IsoWindows
        output_dir = $WindowsOut
        iso_checksum = $IsoChecksum
    }

    Invoke-PackerInit     $Wtpl $LogW
    Invoke-PackerValidate $Wtpl $LogW $varsW
    Invoke-PackerBuild    $Wtpl $LogW $varsW $WindowsMaxMinutes
}
catch {
    Write-Fail "Windows build failed: $($_.Exception.Message)"
    exit 1
}