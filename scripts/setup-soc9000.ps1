[CmdletBinding()]
param(
    [switch]$ManualNetwork,
    [string]$ArtifactsDir,
    [string]$IsoDir,
    [switch]$AutoPartitionE,
    [switch]$SkipPrereqs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -------------------- UX Helpers (ASCII) --------------------
function Write-Banner {
    param(
        [string]$Title, 
        [string]$Subtitle = '', 
        [ConsoleColor]$Color = [ConsoleColor]::Cyan
    )
    $line = '============================================================================'
    Write-Host ''
    Write-Host $line -ForegroundColor $Color
    Write-Host ('  >> {0}' -f $Title) -ForegroundColor $Color
    if ($Subtitle) { Write-Host ('     {0}' -f $Subtitle) -ForegroundColor DarkGray }
    Write-Host $line -ForegroundColor $Color
}

function Write-Line {
    param(
        [string]$Text, 
        [string]$Kind = 'info'
    )
    $fg = @{ info='Gray'; ok='Green'; warn='Yellow'; err='Red'; step='White'; ask='Magenta' }[$Kind]
    $tag = @{ info='[i]'; ok='[OK]'; warn='[!]'; err='[X]'; step='[>]'; ask='[?]' }[$Kind]
    Write-Host ('  {0} {1}' -f $tag, $Text) -ForegroundColor $fg
}

function Write-Panel {
    param(
        [string]$Title, 
        [string[]]$Lines
    )
    $line = '+--------------------------------------------------------------------------+'
    Write-Host $line -ForegroundColor DarkCyan
    Write-Host ('| {0}' -f $Title) -ForegroundColor DarkCyan
    Write-Host $line -ForegroundColor DarkCyan
    foreach ($ln in $Lines) { Write-Host ('| {0}' -f $ln) }
    Write-Host $line -ForegroundColor DarkCyan
}

function Refresh-Path {
    $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
                [Environment]::GetEnvironmentVariable('Path','User')
}

# -------------------- Elevation & Shell helpers --------------------
function Test-AdminPrivileges {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Ensure-AdminPrivileges {
    if (Test-AdminPrivileges) { return }
    
    Write-Host 'Requesting elevation...' -ForegroundColor Cyan
    $exe = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh' } else { 'powershell' }
    $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"") + $MyInvocation.UnboundArguments
    Start-Process -FilePath $exe -Verb RunAs -ArgumentList $args | Out-Null
    exit 0
}

function Get-PreferredShell {
    $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($pwsh) { return 'pwsh' }
    return 'powershell'
}

function Get-HeadlessChoice {
    do {
        Write-Host ''
        Write-Host 'Build display mode:' -ForegroundColor Cyan
        Write-Host '  [G] UI (show VMware console during install)' -ForegroundColor Gray
        Write-Host '  [H] Headless (no GUI)' -ForegroundColor Gray
        $ans = Read-Host 'Choose (G/h)'
        if (-not $ans) { $ans = 'G' }
        
        switch -regex ($ans.Trim()) {
            '^(g|gui)$'      { return $false }
            '^(h|headless)$' { return $true  }
            default          { Write-Host 'Please enter G or H.' -ForegroundColor Yellow }
        }
    } while ($true)
}

function Load-EnvironmentFile {
    param([string]$Path)
    
    $envMap = @{}
    if (-not (Test-Path $Path)) { return $envMap }
    
    foreach ($line in Get-Content $Path) {
        if ($line -match '^\s*#' -or $line -match '^\s*$') { continue }
        $k, $v = $line -split '=', 2
        if ($k -and $v) { $envMap[$k.Trim()] = $v.Trim() }
    }
    return $envMap
}

function Test-RepositoryStructure {
    param([string]$RepoPath)
    
    $sentinels = @(
        (Join-Path $RepoPath 'scripts\build-packer.ps1'),
        (Join-Path $RepoPath 'scripts\download-isos.ps1'),
        (Join-Path $RepoPath 'packer\ubuntu-container\ubuntu-container.pkr.hcl')
    )
    
    foreach ($s in $sentinels) {
        if (-not (Test-Path $s)) { return $false }
    }
    return $true
}

function Get-UbuntuUsername {
    param([hashtable]$EnvMap, [string]$RepoRoot)
    
    $username = $EnvMap['UBUNTU_USERNAME']
    if ($username) { return $username }
    
    $userDataPath = Join-Path $RepoRoot 'packer\ubuntu-container\http\user-data'
    if (Test-Path $userDataPath) {
        $content = Get-Content $userDataPath -Raw
        if ($content -match '^\s*username:\s*(\S+)') {
            return $matches[1].Trim()
        }
    }
    
    return 'labadmin'
}

function Get-SSHKeyInfo {
    param([string]$SshDir)
    
    $privKeys = @()
    $pubKeys = @()
    
    $keyTypes = @('id_ed25519', 'id_rsa')
    foreach ($keyType in $keyTypes) {
        $privPath = Join-Path $SshDir $keyType
        $pubPath = "$privPath.pub"
        
        if (Test-Path $privPath) {
            $privKeys += $privPath
            if (Test-Path $pubPath) {
                $pubKeys += $pubPath
            }
        }
    }
    
    return @{ PrivateKeys = $privKeys; PublicKeys = $pubKeys }
}

function Get-UbuntuVMXPath {
    param([string]$InstallRoot)
    
    $stateDir = Join-Path $InstallRoot 'state'
    $stateFile = Join-Path $stateDir 'packer-artifacts.json'
    
    if (Test-Path $stateFile) {
        try {
            $json = Get-Content $stateFile -Raw | ConvertFrom-Json
            if ($json.ubuntu.vmx) { return $json.ubuntu.vmx }
        }
        catch {
            Write-Line "Failed to parse state file: $($_.Exception.Message)" "warn"
        }
    }
    
    $vmxPath = Get-ChildItem -Path (Join-Path $InstallRoot 'VMs\Ubuntu') -Filter *.vmx -Recurse -ErrorAction SilentlyContinue |
               Select-Object -First 1 -ExpandProperty FullName
    return $vmxPath
}

# Main execution
try {
    # Check and request admin privileges
    Ensure-AdminPrivileges
    
    # Initialize paths and directories
    $ScriptRoot = Split-Path -Parent $PSCommandPath
    $RepoRoot = (Resolve-Path (Join-Path $ScriptRoot '..')).Path
    $EnvFile = Join-Path $RepoRoot '.env'
    
    $InstallRoot = if (Test-Path 'E:\') { 'E:\SOC-9000-Install' } else { 'C:\SOC-9000-Install' }
    $LogRoot = Join-Path $InstallRoot 'logs'
    $SetupLogDir = Join-Path $LogRoot 'setup'
    $PackerLogDir = Join-Path $LogRoot 'packer'
    $IsoRoot = if ($IsoDir) { $IsoDir } else { Join-Path $InstallRoot 'isos' }
    
    # Create directories
    New-Item -ItemType Directory -Force -Path $InstallRoot, $LogRoot, $SetupLogDir, $PackerLogDir, $IsoRoot | Out-Null
    
    # Start transcript
    $timestamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $TranscriptPath = Join-Path $SetupLogDir ('setup-{0}.log' -f $timestamp)
    try { Start-Transcript -Path $TranscriptPath -Force | Out-Null } catch {}
    
    # Load environment file
    $EnvMap = Load-EnvironmentFile -Path $EnvFile
    
    # Display session overview
    $overview = @(
        ('Repo Root     : {0}' -f $RepoRoot),
        ('ISOs Path     : {0}' -f $IsoRoot),
        ('Logs (setup)  : {0}' -f $SetupLogDir),
        ('Logs (packer) : {0}' -f $PackerLogDir),
        ('User          : {0}@{1}' -f $env:USERNAME, $env:COMPUTERNAME),
        ('Shell         : PowerShell {0} {1}' -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition),
        ('Started       : {0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    )
    
    Write-Banner 'SOC-9000 Setup Orchestrator' 'Steps 1-6 with clean, readable UX'
    Write-Panel 'Session Overview' $overview
    
    # Step 1: Prerequisites
    if (-not $SkipPrereqs) {
        Write-Banner 'Step 1 of 6 - Prerequisites' 'Runs install-prereqs.ps1; may prompt for VMware install or reboot.'
    
        $preReqsScript = Join-Path $RepoRoot 'scripts\install-prereqs.ps1'
        $shell = Get-PreferredShell
    
        if ($AutoPartitionE) {
            & $shell -NoProfile -ExecutionPolicy Bypass -File $preReqsScript -AutoPartitionE -Verbose
        } else {
            & $shell -NoProfile -ExecutionPolicy Bypass -File $preReqsScript -Verbose
        }
    
        # Handle different exit codes
        switch ($LASTEXITCODE) {
            2 {
                Write-Line 'Prereqs complete; a reboot is required to finalize WSL activation.' 'warn'
                Read-Host '  [?] Press ENTER to reboot now' | Out-Null
                try { Stop-Transcript | Out-Null } catch {}
                Restart-Computer -Force
                exit
            }
            3 {
                # User chose to abort
                Write-Line 'Prerequisites installation aborted by user.' 'warn'
                try { Stop-Transcript | Out-Null } catch {}
                exit 0
            }
            { $_ -ne 0 } {
                throw ('install-prereqs.ps1 failed with exit code {0}' -f $LASTEXITCODE)
            }
        }
    
        Write-Line 'Prerequisites complete.' 'ok'
        
        # Switch to PowerShell 7 if available
        Refresh-Path
        $hasPwsh = Get-Command pwsh -ErrorAction SilentlyContinue
        $isCore = $PSVersionTable.PSEdition -eq 'Core'
        
        if ($hasPwsh -and -not $isCore) {
            Write-Line 'Switching to PowerShell 7 for remaining steps...' 'info'
            $unboundArgs = $MyInvocation.UnboundArguments + @('-SkipPrereqs')
            $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"") + $unboundArgs
            Start-Process -FilePath 'pwsh' -Verb RunAs -ArgumentList $args | Out-Null
            try { Stop-Transcript | Out-Null } catch {}
            exit 0
        }
    } else {
        Write-Line 'SkipPrereqs flag detected — continuing at Step 2.' 'info'
    }
    
    # Step 2: Repository Check
    Write-Banner 'Step 2 of 6 - Repository' 'Using the current working tree; cloning disabled.'
    
    if (-not (Test-RepositoryStructure -RepoPath $RepoRoot)) {
        throw "This folder doesn't look like SOC-9000. Open an elevated PowerShell in your cloned repo and rerun scripts\setup-soc9000.ps1."
    }
    
    Write-Line ("Using current tree: {0}" -f $RepoRoot) 'ok'
    
    # Step 3: Directories & ISOs
    Write-Banner 'Step 3 of 6 - Directories and ISO Validation' 'Verifies ISOs; opens official vendor pages when manual download is needed.'
    
    New-Item -ItemType Directory -Force -Path (Join-Path $InstallRoot 'artifacts') | Out-Null
    Write-Line 'Running ISO downloader...' 'step'
    
    $shell = Get-PreferredShell
    $downloadScript = Join-Path $RepoRoot 'scripts\download-isos.ps1'
    & $shell -NoProfile -ExecutionPolicy Bypass -File $downloadScript -IsoDir $IsoRoot -Verbose
    
    $isos = Get-ChildItem -Path $IsoRoot -Filter *.iso -ErrorAction SilentlyContinue
    if (-not $isos -or $isos.Count -eq 0) {
        Write-Line ('No ISO detected in {0}.' -f $IsoRoot) 'warn'
        Read-Host '  [?] Place the required ISO(s) into the folder above, then press ENTER to re-check' | Out-Null
        $isos = Get-ChildItem -Path $IsoRoot -Filter *.iso -ErrorAction SilentlyContinue
        if (-not $isos -or $isos.Count -eq 0) { throw 'ISO(s) still missing; cannot continue.' }
    }
    
    Write-Line ('{0} ISO(s) present.' -f $isos.Count) 'ok'
    
    # Step 4: Networking
    Write-Banner 'Step 4 of 6 - VMware Networking' 'Verify first; configure only if needed.'
    Write-Line 'Verifying VMware networks...' 'step'
    
    $verifyScript = Join-Path $RepoRoot 'scripts\verify-networking.ps1'
    & $shell -NoProfile -ExecutionPolicy Bypass -File $verifyScript -Verbose
    
    if ($LASTEXITCODE -ne 0) {
        Write-Line 'Verification failed; applying configuration from .env ...' 'warn'
        
        if ($ManualNetwork) {
            $vmnetcfg = @(
                "${env:ProgramFiles}\VMware\VMware Workstation\vmnetcfg.exe",
                "${env:ProgramFiles(x86)}\VMware\VMware Workstation\vmnetcfg.exe"
            ) | Where-Object { Test-Path $_ } | Select-Object -First 1
            
            if ($vmnetcfg) {
                & $vmnetcfg
            } else {
                Write-Line 'vmnetcfg.exe not found; proceeding with automated script.' 'warn'
            }
        }
        
        $configureScript = Join-Path $RepoRoot 'scripts\configure-vmnet.ps1'
        & $shell -NoProfile -ExecutionPolicy Bypass -File $configureScript -Verbose
        
        if ($LASTEXITCODE -ne 0) {
            throw ('Automated network configuration failed (configure-vmnet.ps1 exit {0}).' -f $LASTEXITCODE)
        }
        
        Write-Line 'Re-verifying VMware networks...' 'step'
        & $shell -NoProfile -ExecutionPolicy Bypass -File $verifyScript -Verbose
        
        if ($LASTEXITCODE -ne 0) {
            throw 'Networking verification failed after configuration.'
        }
        
        Write-Line 'Networks configured.' 'ok'
    } else {
        Write-Line 'Networks already correctly configured; no changes applied.' 'ok'
    }
    
    # Step 5: WSL & SSH Keys
    Write-Banner 'Step 5 of 6 - WSL Check and SSH Keys' 'Quick WSL ping; generate host SSH keys if missing; initialize WSL user.'
    Write-Line 'WSL quick status...' 'step'
    
    try {
        wsl.exe --status | Out-Null
        Write-Line 'WSL responding.' 'ok'
    } catch {
        Write-Line ('WSL status warning: {0}' -f $_.Exception.Message) 'warn'
    }
    
    $sshDir = Join-Path $env:USERPROFILE '.ssh'
    $sshKeyInfo = Get-SSHKeyInfo -SshDir $sshDir
    
    if ($sshKeyInfo.PrivateKeys.Count -eq 0) {
        Write-Line 'Generating host SSH keypair (ed25519 preferred)...' 'step'
        New-Item -ItemType Directory -Force -Path $sshDir | Out-Null
        
        try {
            ssh-keygen -t ed25519 -N '' -f (Join-Path $sshDir 'id_ed25519') | Out-Null
            Write-Line 'ed25519 key generated.' 'ok'
        } catch {
            ssh-keygen -t rsa -b 4096 -N '' -f (Join-Path $sshDir 'id_rsa') | Out-Null
            Write-Line 'RSA-4096 key generated.' 'ok'
        }
    } else {
        Write-Line 'Host SSH key(s) already present.' 'ok'
    }
    
    $wslPrepareScript = Join-Path $RepoRoot 'scripts\wsl-prepare.ps1'
    $wslInitScript = Join-Path $RepoRoot 'scripts\wsl-init-user.ps1'
    
    & $shell -NoProfile -ExecutionPolicy Bypass -File $wslPrepareScript -Verbose
    & $shell -NoProfile -ExecutionPolicy Bypass -File $wslInitScript -Verbose
    
    # Step 6: Build (Ubuntu first)
    Write-Banner 'Step 6 of 6 - Build Lab (Ubuntu First)' 'Using headless mode for reliable builds'
    New-Item -ItemType Directory -Force -Path $PackerLogDir | Out-Null

    $ubuntuLog = Join-Path $PackerLogDir ('ubuntu-{0}.log' -f (Get-Date).ToString('yyyyMMdd-HHmmss'))

    # Force headless mode
    $env:PACKER_HEADLESS = 'true'

    $buildScript = Join-Path $RepoRoot 'scripts\build-packer.ps1'
    $buildArgs = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', $buildScript,
        '-Only', 'ubuntu',
        '-Headless',
        '-Verbose'
    )

    Write-Line ("Starting Ubuntu build in HEADLESS mode; logging to: {0}" -f $ubuntuLog) 'step'

    & $shell @buildArgs 2>&1 | Tee-Object -FilePath $ubuntuLog

    if ($LASTEXITCODE -ne 0) {
    throw ('Ubuntu build failed. See {0}' -f $ubuntuLog)
    }

    Write-Line 'Ubuntu build completed.' 'ok'

    # NEW: Windows build section
    Write-Banner 'Step 7 of 7 - Build Windows VM' 'Building Windows victim machine'

    $windowsLog = Join-Path $PackerLogDir ('windows-{0}.log' -f (Get-Date).ToString('yyyyMMdd-HHmmss'))

    $buildArgs = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', $buildScript,
        '-Only', 'windows',
        '-Headless',
        '-Verbose'
    )

    Write-Line ("Starting Windows build in HEADLESS mode; logging to: {0}" -f $windowsLog) 'step'

    & $shell @buildArgs 2>&1 | Tee-Object -FilePath $windowsLog

    if ($LASTEXITCODE -ne 0) {
        throw ('Windows build failed. See {0}' -f $windowsLog)
    }

    Write-Line 'Windows build completed.' 'ok'

    # Credential Summary
    $ubuntuUser = Get-UbuntuUsername -EnvMap $EnvMap -RepoRoot $RepoRoot
    $sshKeyInfo = Get-SSHKeyInfo -SshDir $sshDir
    $ubuntuVMX = Get-UbuntuVMXPath -InstallRoot $InstallRoot
    $userDataPath = Join-Path $RepoRoot 'packer\ubuntu-container\http\user-data'
    $stateDir = Join-Path $InstallRoot 'state'
    $stateFile = Join-Path $stateDir 'packer-artifacts.json'

    # Remove the problematic if statements from the credential panel
    $credentialPanel = @(
        ('Username            : {0}' -f $ubuntuUser),
        ('Password login      : disabled (SSH key auth)'),
        ('SSH private key(s)  : {0}' -f ($sshKeyInfo.PrivateKeys -join ', ')),
        ('SSH public key(s)   : {0}' -f ($sshKeyInfo.PublicKeys -join ', ')),
        ('VMX path            : {0}' -f $ubuntuVMX),
        '',
        ('Defined in .env     : {0}' -f $EnvFile),
        ('Autoinstall file    : {0}' -f $userDataPath),
        ('State JSON          : {0}' -f $stateFile)
)

    $logsPanel = @(
        ('Packer logs         : {0}' -f $PackerLogDir),
        ('Setup transcript    : {0}' -f $TranscriptPath),
        ('ISOs directory      : {0}' -f $IsoRoot),
        'VMware Workstation  : Library -> Ubuntu -> Console'
)

    Write-Panel 'Ubuntu Access & Credentials' $credentialPanel
    Write-Panel 'Logs & Artifacts' $logsPanel

    Read-Host '  [?] Press ENTER to finish' | Out-Null

    Write-Banner 'Setup Steps 1-6 Complete' 'You can proceed to Step 7 (Windows) when ready.'
    Write-Host 'NOTE: Credentials shown above also appear in this transcript log.' -ForegroundColor Yellow
}
catch {
    Write-Line ('Unexpected error: {0}' -f $_.Exception.Message) 'err'
    Read-Host 'Press ENTER to exit' | Out-Null
    exit 1
}
finally {
    try { Stop-Transcript | Out-Null } catch {}
}