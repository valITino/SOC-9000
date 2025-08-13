[CmdletBinding()]
param(
    [string]$IsoDir,

    # Optional overrides; can also be provided via .env
    [string]$UbuntuUrl  = $null,
    [string]$PfSenseUrl = $null,   # If set, try this first; fallback to mirrors below
    [string]$Win11Url   = $null,   # Expiring; open vendor page if empty
    [string]$NessusUrl  = $null    # Gated; open vendor page if empty
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Nudge TLS12 for older hosts
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

function Write-Info($m){ Write-Host $m -ForegroundColor Cyan }
function Write-Good($m){ Write-Host $m -ForegroundColor Green }
function Write-Warn($m){ Write-Warning $m }
function Write-Err ($m){ Write-Error   $m }

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
# NOTE: pfSense links/mirrors change; we keep a short list and also open the download page if all fail.
$pfMirrors = @(
  'https://mirror.pfsense.org/amd64/installer/pfSense-CE-2.7.3-RELEASE-amd64.iso',
  'https://atxfiles.pfsense.org/mirror/downloads/pfSense-CE-2.7.3-RELEASE-amd64.iso',
  'https://frafiles.pfsense.org/mirror/downloads/pfSense-CE-2.7.3-RELEASE-amd64.iso',
  'https://nyifiles.pfsense.org/mirror/downloads/pfSense-CE-2.7.3-RELEASE-amd64.iso'
)

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
    $ua = @{ 'User-Agent' = 'SOC-9000/installer' }
    for ($i=1; $i -le $MaxTries; $i++) {
        try {
            Write-Info "[*] Downloading $(Split-Path -Leaf $OutFile) (try $i/$MaxTries)..."
            $resp = Invoke-WebRequest -Uri $Uri -OutFile $OutFile -Headers $ua -TimeoutSec $TimeoutSec -UseBasicParsing -ErrorAction Stop
            $ct = $resp.Headers['Content-Type']
            if ($ct -and -not ($AllowedIsoContentTypes -contains $ct)) {
                Write-Warn "Downloaded but content-type '$ct' is unusual for ISO; keeping file."
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

function Ensure-OrOpenVendor {
    param(
        [Parameter(Mandatory)] [string]$OutFile,
        [string]$UrlIfAny,
        [string]$VendorPage
    )
    if (Test-Path $OutFile) { Write-Good "[=] Exists: $(Split-Path -Leaf $OutFile)"; return }
    if ($UrlIfAny) {
        if (Invoke-Download -Uri $UrlIfAny -OutFile $OutFile) { return }
    }
    Write-Warn "$(Split-Path -Leaf $OutFile) requires a gated or expiring URL. Opening vendor page…"
    if ($VendorPage) { try { Start-Process $VendorPage } catch { Write-Warn "Could not open browser: $($_.Exception.Message)" } }
    Write-Info  "Please download manually and place it at: $OutFile"
}

# Targets
$UbuntuIso  = Join-Path $IsoDir 'ubuntu-22.04.iso'
$PfSenseIso = Join-Path $IsoDir 'pfsense.iso'
$Win11Iso   = Join-Path $IsoDir 'win11-eval.iso'
$NessusDeb  = Join-Path $IsoDir 'nessus_latest_amd64.deb'

# Ubuntu (static)
Ensure-FromUrls -OutFile $UbuntuIso -Urls @($UbuntuUrl) | Out-Null

# pfSense (try override then mirrors; if all fail, open download page)
$pfList = @()
if ($PfSenseUrl) { $pfList += $PfSenseUrl }
$pfList += $pfMirrors
if (-not (Ensure-FromUrls -OutFile $PfSenseIso -Urls $pfList)) {
    Write-Warn "pfSense ISO could not be fetched from mirrors. This can be DNS or certificate time issues."
    Write-Info "Opening pfSense download page so you can pick a nearby mirror…"
    try { Start-Process 'https://www.pfsense.org/download/' } catch {}
    Write-Info "After download, save as: $PfSenseIso"
}

# Windows 11 Eval (expiring)
Ensure-OrOpenVendor -OutFile $Win11Iso -UrlIfAny $Win11Url -VendorPage 'https://www.microsoft.com/en-us/evalcenter/evaluate-windows-11-enterprise'

# Nessus (gated)
Ensure-OrOpenVendor -OutFile $NessusDeb -UrlIfAny $NessusUrl -VendorPage 'https://www.tenable.com/products/nessus/nessus-essentials'

Write-Good "All downloads complete (or vendor pages opened)."
