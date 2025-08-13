[CmdletBinding()]
param(
    [string]$IsoDir,

    # Optional overrides; can also be provided via .env
    [string]$UbuntuUrl  = $null,
    # pfSense ISO: if provided, the script will attempt to download from this URL.  If omitted,
    # the pfSense download page will be opened directly for a manual download.
    [string]$PfSenseUrl = $null,
    # Windows 11 ISO: provide a direct download URL to attempt an automated fetch.
    [string]$Win11Url   = $null,
    # Nessus package: provide a direct download URL to attempt an automated fetch.
    [string]$NessusUrl  = $null
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Nudge TLS12 for older hosts
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

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

# pfSense downloads previously attempted to use multiple mirrors to fetch the ISO.
# In practice these URLs often fail due to DNS or certificate issues.  To simplify
# the user experience, we no longer try a series of mirrors.  Instead, if a
# specific URL is provided via -PfSenseUrl we will attempt to download from it;
# otherwise we immediately open the pfSense vendor page so the user can choose
# their nearest mirror manually.  See the pfSense documentation for details.
$pfMirrors = @()

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
    # If the file already exists, nothing to do
    if (Test-Path $OutFile) {
        Write-Good "[=] Exists: $(Split-Path -Leaf $OutFile)"
        return
    }
    # Attempt direct download if a URL override was provided
    if ($UrlIfAny) {
        if (Invoke-Download -Uri $UrlIfAny -OutFile $OutFile) { return }
    }
    # Fall back to manual download: open the vendor page and defer prompting
    Write-Warn "$(Split-Path -Leaf $OutFile) requires a gated or expiring URL. Opening vendor page…"
    if ($VendorPage) {
        try { Start-Process $VendorPage } catch { Write-Warn "Could not open browser: $($_.Exception.Message)" }
    }
    Write-Info "Please download manually and place it at: $OutFile"
    # Record that a manual download is needed; the unified prompt at the end
    # will wait for the user to press Enter once all manual downloads are complete.
    $script:manualFilesNeeded = $true
}

# Targets
$UbuntuIso  = Join-Path $IsoDir 'ubuntu-22.04.iso'
$PfSenseIso = Join-Path $IsoDir 'pfsense.iso'
$Win11Iso   = Join-Path $IsoDir 'win11-eval.iso'
$NessusDeb  = Join-Path $IsoDir 'nessus_latest_amd64.deb'

# Ubuntu (static)
Ensure-FromUrls -OutFile $UbuntuIso -Urls @($UbuntuUrl) | Out-Null

# pfSense: open vendor page for manual download by default.  If a PfSenseUrl
# override is supplied, attempt a direct download; otherwise open the pfSense
# download page for the user.
Ensure-OrOpenVendor -OutFile $PfSenseIso -UrlIfAny $PfSenseUrl -VendorPage 'https://www.pfsense.org/download/'

# Windows 11 ISO (International)
# The official Microsoft download page requires you to choose an edition and language
# and provides a time-limited URL for the ISO.  If you provide a direct URL via
# -Win11Url, the installer will attempt to download it.  Otherwise the script
# opens the official download page where you can select "Windows 11" and language
# "English International" (x64) and save the ISO.  Once downloaded, copy or
# rename the file into ISO_DIR.  If you download a file with a different name
# (e.g. Win11_23H2_EnglishInternational_x64.iso), simply rename it to match
# $Win11Iso or adjust your .env ISO_DIR accordingly.
Ensure-OrOpenVendor -OutFile $Win11Iso -UrlIfAny $Win11Url -VendorPage 'https://www.microsoft.com/de-de/software-download/windows11'

# Nessus (gated)
# Tenable’s Nessus downloads require you to sign up for a Nessus Essentials key
# before the download link becomes available.  If no direct URL is provided
# via -NessusUrl, the installer will open the Nessus Essentials registration
# page.  Register with a disposable email address, obtain the download link and
# save the .deb package into your ISO_DIR.  After placing the file, press
# Enter when prompted to continue.
Ensure-OrOpenVendor -OutFile $NessusDeb -UrlIfAny $NessusUrl -VendorPage 'https://www.tenable.com/products/nessus/nessus-essentials'

# Unified prompt: if any manual downloads were required, prompt once at the end
if ($script:manualFilesNeeded) {
    Write-Host "Press Enter after you have downloaded and placed all required files to continue..." -ForegroundColor Yellow
    Read-Host | Out-Null
    $script:manualFilesNeeded = $false
}