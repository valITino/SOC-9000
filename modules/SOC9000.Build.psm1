<#
.SYNOPSIS
    SOC9000 Build Module - Common Packer and VMware build helpers.

.DESCRIPTION
    Provides reusable functions for building VM images with Packer:
    - Packer executable discovery
    - Packer init/validate/build wrappers
    - Build progress tracking
    - Artifact verification
    - ISO discovery and validation

.NOTES
    Version: 1.0.0
    Requires: PowerShell 7.2+
#>

#requires -Version 7.2

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Import utilities
Import-Module (Join-Path $PSScriptRoot 'SOC9000.Utils.psm1') -Force

# ==================== PACKER DISCOVERY ====================

<#
.SYNOPSIS
    Finds the Packer executable on the system.

.DESCRIPTION
    Searches common installation locations for packer.exe.

.EXAMPLE
    $packerPath = Find-PackerExecutable
#>
function Find-PackerExecutable {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    # 1) Check PATH
    $cmd = Get-Command packer -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Path) { return $cmd.Path }

    # 2) Common install locations
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\packer.exe'),
        (Join-Path $env:LOCALAPPDATA 'HashiCorp\Packer\packer.exe'),
        (Join-Path $env:ProgramFiles 'HashiCorp\Packer\packer.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'HashiCorp\Packer\packer.exe'),
        (Join-Path $env:ChocolateyInstall 'bin\packer.exe'),
        'C:\ProgramData\chocolatey\bin\packer.exe'
    ) | Where-Object { $_ }

    foreach ($p in $candidates) {
        try {
            if (Test-Path -LiteralPath $p) { return (Resolve-Path -LiteralPath $p).Path }
        }
        catch { }
    }

    # 3) Search HashiCorp and WinGet directories
    $roots = @(
        (Join-Path $env:LOCALAPPDATA 'HashiCorp'),
        (Join-Path $env:ProgramFiles 'HashiCorp'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages')
    ) | Where-Object { $_ -and (Test-Path $_) }

    foreach ($r in $roots) {
        try {
            $found = Get-ChildItem -Path $r -Filter 'packer.exe' -Recurse -ErrorAction SilentlyContinue |
                Select-Object -First 1 -ExpandProperty FullName
            if ($found) { return $found }
        }
        catch { }
    }

    return $null
}

# ==================== ISO DISCOVERY ====================

<#
.SYNOPSIS
    Finds an ISO file matching patterns in a directory.

.PARAMETER Directory
    Directory to search.

.PARAMETER Patterns
    Array of filename patterns (e.g., 'ubuntu-*.iso').

.EXAMPLE
    $iso = Find-IsoFile -Directory 'C:\ISOs' -Patterns @('ubuntu-22.04*.iso')
#>
function Find-IsoFile {
    [CmdletBinding()]
    [OutputType([System.IO.FileInfo])]
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string[]]$Patterns
    )

    if (-not (Test-Path -LiteralPath $Directory)) { return $null }

    $candidates = foreach ($pat in $Patterns) {
        Get-ChildItem -LiteralPath $Directory -Filter $pat -ErrorAction SilentlyContinue
    }

    return $candidates | Sort-Object LastWriteTime -Descending | Select-Object -First 1
}

# ==================== PACKER OPERATIONS ====================

<#
.SYNOPSIS
    Initializes a Packer template.
#>
function Invoke-PackerInit {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TemplatePath,
        [Parameter(Mandatory)][string]$PackerExe,
        [Parameter(Mandatory)][string]$LogPath
    )

    $tplDir = [System.IO.Path]::GetDirectoryName($TemplatePath)
    $tplLeaf = [System.IO.Path]::GetFileName($TemplatePath)

    Write-InfoLog "Initializing Packer template: $tplLeaf"

    Push-Location $tplDir
    try {
        & $PackerExe init $tplLeaf 2>&1 | Tee-Object -FilePath $LogPath -Append
        if ($LASTEXITCODE -ne 0) {
            throw "packer init failed with exit code $LASTEXITCODE"
        }
    }
    finally { Pop-Location }
}

<#
.SYNOPSIS
    Validates a Packer template with variables.
#>
function Invoke-PackerValidate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TemplatePath,
        [Parameter(Mandatory)][string]$PackerExe,
        [Parameter(Mandatory)][string]$LogPath,
        [hashtable]$Variables = @{}
    )

    $tplDir = [System.IO.Path]::GetDirectoryName($TemplatePath)
    $tplLeaf = [System.IO.Path]::GetFileName($TemplatePath)

    Write-InfoLog "Validating Packer template: $tplLeaf"

    $args = @('validate')
    foreach ($k in $Variables.Keys) {
        $args += @('-var', ("{0}={1}" -f $k, $Variables[$k]))
    }
    $args += $tplLeaf

    Push-Location $tplDir
    try {
        & $PackerExe @args 2>&1 | Tee-Object -FilePath $LogPath -Append
        if ($LASTEXITCODE -ne 0) {
            throw "packer validate failed with exit code $LASTEXITCODE"
        }
    }
    finally { Pop-Location }
}

<#
.SYNOPSIS
    Runs a Packer build with progress tracking.
#>
function Invoke-PackerBuild {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TemplatePath,
        [Parameter(Mandatory)][string]$PackerExe,
        [Parameter(Mandatory)][string]$LogPath,
        [hashtable]$Variables = @{},
        [int]$TimeoutMinutes = 120
    )

    $env:PACKER_LOG = '1'
    $env:PACKER_LOG_PATH = $LogPath

    $tplDir = [System.IO.Path]::GetDirectoryName($TemplatePath)
    $tplLeaf = [System.IO.Path]::GetFileName($TemplatePath)

    Write-InfoLog "Starting Packer build: $tplLeaf"

    $args = @('build', '-timestamp-ui', '-force')
    foreach ($k in $Variables.Keys) {
        $args += @('-var', ("{0}={1}" -f $k, $Variables[$k]))
    }
    $args += $tplLeaf

    # Build argument string for Start-Process
    $argStr = ($args | ForEach-Object {
            if ($_ -match '[\s"`]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
        }) -join ' '

    $process = Start-Process -FilePath $PackerExe -ArgumentList $argStr -PassThru -WorkingDirectory $tplDir

    $start = Get-Date
    while (-not $process.HasExited) {
        Show-PackerProgress -LogPath $LogPath -StartTime $start -TimeoutMinutes $TimeoutMinutes

        if (((Get-Date) - $start).TotalMinutes -ge $TimeoutMinutes) {
            try { Stop-Process -Id $process.Id -Force } catch { }
            throw "Packer build timed out after $TimeoutMinutes minutes"
        }

        Start-Sleep -Seconds 5
        try { $process.Refresh() } catch { }
    }

    if ($process.ExitCode -ne 0) {
        $tail = ''
        if (Test-Path -LiteralPath $LogPath) {
            $tail = ((Get-Content -LiteralPath $LogPath -Tail 50 -ErrorAction SilentlyContinue) -join "`n")
        }
        throw "Packer build failed with exit code $($process.ExitCode)`n--- Last 50 lines ---`n$tail"
    }

    Write-Progress -Activity "Packer build" -Completed
    Write-SuccessLog "Build completed: $LogPath"
}

<#
.SYNOPSIS
    Shows progress for a running Packer build.
#>
function Show-PackerProgress {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LogPath,
        [Parameter(Mandatory)][datetime]$StartTime,
        [int]$TimeoutMinutes
    )

    $stages = @(
        @{ Name = 'Booting ISO'; Pattern = '(boot|Starting HTTP|vmware-iso: VM)' },
        @{ Name = 'Waiting for SSH'; Pattern = 'Waiting for SSH' },
        @{ Name = 'Connected via SSH'; Pattern = 'Connected to SSH|SSH handshake' },
        @{ Name = 'Provisioning'; Pattern = 'Provisioning|Uploading|Executing' },
        @{ Name = 'Shutdown'; Pattern = 'Gracefully|Stopping|Powering off' },
        @{ Name = 'Artifact complete'; Pattern = 'Builds finished|Artifact' }
    )

    $text = ''
    if (Test-Path -LiteralPath $LogPath) {
        $text = ((Get-Content -LiteralPath $LogPath -Tail 200 -ErrorAction SilentlyContinue) -join "`n")
    }

    $done = 0
    foreach ($s in $stages) {
        if ($text -match $s.Pattern) { $done++ }
    }

    $pct = [int](($done / $stages.Count) * 100)
    $elapsed = (Get-Date) - $StartTime
    $limit = [TimeSpan]::FromMinutes($TimeoutMinutes)

    Write-Progress -Activity "Packer build" `
        -Status ("Elapsed {0:hh\:mm\:ss} / {1:hh\:mm}" -f $elapsed, $limit) `
        -PercentComplete $pct
}

# ==================== ARTIFACT VERIFICATION ====================

<#
.SYNOPSIS
    Waits for and verifies VM artifacts are created.

.PARAMETER Targets
    Array of hashtables with Name, Directory, and Pattern keys.

.PARAMETER MaxWaitSeconds
    Maximum time to wait for artifacts (default: 120).

.EXAMPLE
    $targets = @(
        @{ Name = 'Ubuntu'; Directory = 'C:\VMs\Ubuntu'; Pattern = '*.vmx' }
    )
    $artifacts = Wait-ForVMxArtifacts -Targets $targets
#>
function Wait-ForVMxArtifacts {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][array]$Targets,
        [int]$MaxWaitSeconds = 120
    )

    $start = Get-Date
    $found = @{}

    do {
        $ready = 0
        foreach ($t in $Targets) {
            if ($found.ContainsKey($t.Name)) {
                $ready++
                continue
            }

            if (Test-Path -LiteralPath $t.Directory) {
                $vmx = Get-ChildItem -Path $t.Directory -Filter $t.Pattern -Recurse -ErrorAction SilentlyContinue |
                Select-Object -First 1

                if ($vmx) {
                    $found[$t.Name] = $vmx.FullName
                    $ready++
                }
            }
        }

        $pct = [int](($ready / [math]::Max(1, $Targets.Count)) * 100)
        Write-Progress -Activity "Verifying VM artifacts" -Status ("{0}/{1} ready" -f $ready, $Targets.Count) -PercentComplete $pct

        if ($ready -eq $Targets.Count) {
            Write-Progress -Activity "Verifying VM artifacts" -Completed
            return $found
        }

        Start-Sleep -Seconds 2
    } while (((Get-Date) - $start).TotalSeconds -lt $MaxWaitSeconds)

    $missing = $Targets | Where-Object { -not $found.ContainsKey($_.Name) } |
    ForEach-Object { "{0} in {1}" -f $_.Name, $_.Directory }
    throw "Artifacts not found after $MaxWaitSeconds seconds: $($missing -join '; ')"
}

# ==================== EXPORTS ====================

Export-ModuleMember -Function @(
    'Find-PackerExecutable',
    'Find-IsoFile',
    'Invoke-PackerInit',
    'Invoke-PackerValidate',
    'Invoke-PackerBuild',
    'Show-PackerProgress',
    'Wait-ForVMxArtifacts'
)
