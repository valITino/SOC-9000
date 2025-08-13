[CmdletBinding()]
param(
    [string]$IsoDir,

    # Optional overrides; can also be provided via .env
    [string]$UbuntuUrl  = $null
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Nudge TLS12 for older hosts
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$UA = @{ 'User-Agent' = 'SOC-9000/installer' }

function Write-Info($m){ Write-Host $m -ForegroundColor Cyan }
function Write-Good($m){ Write-Host $m -ForegroundColor Green }
function Write-Warn($m){ Write-Warning $m }
function Write-Err ($m){ Write-Error   $m }

# Global flag to track whether any manual downloads were required.  If set,
# we'll prompt the user once at the end of the script instead of for each
# individual file.
$script:manualFilesNeeded = $false

# Load .env if present for ISO_DIR/URL overrides
$repoDir = Split-Path -Parent $PSCommandPath
$rootDir = Split-Path -Parent $repoDir
$envPath = Join-Path $rootDir '.env'
if (-not $IsoDir) {
    if (Test-Path $envPath) {
        $line = Select-String -Path $envPath -Pattern '^\s*ISO_DIR=(.+)$' -ErrorAction SilentlyContinue
        if ($line) { $IsoDir = $line.Matches.Value.Split('=')[1].Trim() }
    }
    if (-not $IsoDir) { $IsoDir = Join-Path $rootDir 'isos' }
}
New-Item -ItemType Directory -Path $IsoDir -Force | Out-Null

# Defaults (can be overridden by params or .env)
if (-not $UbuntuUrl)  { $UbuntuUrl  = 'https://releases.ubuntu.com/jammy/ubuntu-22.04.5-live-server-amd64.iso' }

# pfSense, Windows 11 and Nessus require gated or expiring URLs.  We no longer
# attempt automatic downloads for these files; instead the script immediately
# opens the vendor page so the user can obtain the latest image manually.

$AllowedIsoContentTypes = @(
  'application/x-iso9660-image','application/octet-stream',
  'application/download','binary/octet-stream','application/x-download'
)

function Invoke-Download {
    param(
        [Parameter(Mandatory)] [string]$Uri,
        [Parameter(Mandatory)] [string]$OutFile,
        [int]$MaxTries = 3,
        [int]$TimeoutSec = 300
    )
    for ($i=1; $i -le $MaxTries; $i++) {
        try {
            Write-Info "[*] Downloading $(Split-Path -Leaf $OutFile) (try $i/$MaxTries)..."
            Invoke-WebRequest -Uri $Uri -OutFile $OutFile -Headers $UA -TimeoutSec $TimeoutSec -UseBasicParsing -ErrorAction Stop

            # Best-effort content-type check using a lightweight HEAD request
            try {
                $head = Invoke-WebRequest -Method Head -Uri $Uri -Headers $UA -TimeoutSec 30 -UseBasicParsing -ErrorAction Stop
                $ct = $head.Headers['Content-Type']
                if ($ct -and -not ($AllowedIsoContentTypes -contains $ct)) {
                    Write-Warn "Downloaded but content-type '$ct' is unusual for ISO; keeping file."
                }
            } catch {
                Write-Warn "Could not inspect headers: $($_.Exception.Message)"
            }

            if ((Test-Path $OutFile) -and ((Get-Item $OutFile).Length -gt 10MB)) {
                $mb = [math]::Round((Get-Item $OutFile).Length/1MB,1)
                Write-Good "[+] Saved $(Split-Path -Leaf $OutFile) ($mb MB)"
                return $true
            } else {
                Write-Warn "File seems too small after download."
            }
        } catch {
            Write-Warn "Download failed: $($_.Exception.Message)"
            Start-Sleep -Seconds ([Math]::Min(5*$i, 20))
        }
    }
    return $false
}

function Ensure-FromUrls {
    param(
        [Parameter(Mandatory)] [string]$OutFile,
        [Parameter(Mandatory)] [string[]]$Urls
    )
    if (Test-Path $OutFile) { Write-Good "[=] Exists: $(Split-Path -Leaf $OutFile)"; return $true }
    foreach ($u in $Urls) {
        if (Invoke-Download -Uri $u -OutFile $OutFile) { return $true }
    }
    return $false
}

function Find-FirstMatchingFile {
    param(
        [Parameter(Mandatory)] [string]$Dir,
        [Parameter(Mandatory)] [string[]]$Patterns
    )
    if (-not (Test-Path $Dir)) { return $null }
    $files = Get-ChildItem -Path $Dir -File -ErrorAction SilentlyContinue
    foreach ($p in $Patterns) {
        $m = $files | Where-Object { $_.Name -match $p } | Select-Object -First 1
        if ($m) { return $m }
    }
    return $null
}

function Open-VendorPage {
    param(
        [Parameter(Mandatory)] [string]$VendorPage,
        [Parameter(Mandatory)] [string]$DisplayName
    )
    Write-Warn "$DisplayName requires manual download. Opening vendor page…"
    try { Start-Process $VendorPage } catch { Write-Warn "Could not open browser: $($_.Exception.Message)" }
    Write-Info "Save the file into $IsoDir with its original name."
    $script:manualFilesNeeded = $true
}

# Targets
$UbuntuIso  = Join-Path $IsoDir 'ubuntu-22.04.iso'

# Ubuntu (static)
Ensure-FromUrls -OutFile $UbuntuIso -Urls @($UbuntuUrl) | Out-Null

# Fetch Ubuntu checksum and convert to per-file .sha256 for verify-hashes
$ubuntuSha = "$UbuntuIso.sha256"
if (-not (Test-Path $ubuntuSha)) {
    try {
        $sumUrl = ($UbuntuUrl -replace '[^/]+$', 'SHA256SUMS')
        $tmpSha = Join-Path $IsoDir 'SHA256SUMS'
        Invoke-WebRequest -Uri $sumUrl -OutFile $tmpSha -Headers $UA -UseBasicParsing -ErrorAction Stop
        $pattern = [regex]::Escape((Split-Path -Leaf $UbuntuUrl))
        $line = Select-String -Path $tmpSha -Pattern $pattern -SimpleMatch | Select-Object -First 1
        if ($line) {
            $hash = ($line.Line -split '\s+')[0]
            Set-Content -Path $ubuntuSha -Value ("$hash  ubuntu-22.04.iso") -Encoding ASCII
        }
        Remove-Item $tmpSha -ErrorAction SilentlyContinue
    } catch {
        Write-Warn "Could not fetch Ubuntu checksum: $($_.Exception.Message)"
    }
}

# pfSense: detect existing file or open vendor page
$pf = Find-FirstMatchingFile -Dir $IsoDir -Patterns @('(?i)(pfsense|netgate).*\.iso$')
if ($pf) {
    Write-Good "[=] Exists: $($pf.Name)"
} else {
    Open-VendorPage -VendorPage 'https://www.pfsense.org/download/' -DisplayName 'pfSense ISO (Netgate account required; burner email OK)'
}

# Windows 11 ISO
$win = Find-FirstMatchingFile -Dir $IsoDir -Patterns @('(?i).*win(dows)?[^\\w]*11.*\.iso$')
if ($win) {
    Write-Good "[=] Exists: $($win.Name)"
} else {
    Open-VendorPage -VendorPage 'https://www.microsoft.com/de-de/software-download/windows11' -DisplayName 'Windows 11 ISO'
}

# Nessus package
$nes = Find-FirstMatchingFile -Dir $IsoDir -Patterns @('(?i)^nessus.*amd64.*\.deb$')
if ($nes) {
    Write-Good "[=] Exists: $($nes.Name)"
} else {
    Open-VendorPage -VendorPage 'https://www.tenable.com/products/nessus/nessus-essentials' -DisplayName 'Nessus Essentials .deb (registration required; burner email OK)'
}

# Unified prompt: if any manual downloads were required, prompt once at the end
if ($script:manualFilesNeeded) {
    Write-Host "Press Enter after you have downloaded and placed all required files to continue..." -ForegroundColor Yellow
    Read-Host | Out-Null
    $script:manualFilesNeeded = $false
}
