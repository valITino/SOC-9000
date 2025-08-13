# SOC-9000 - download-isos.ps1

<#
    This script downloads the required ISO/installer files for the SOC‑9000 lab.  It is intended
    for lab hosts running Windows with Internet access.  Files are downloaded only if they
    are missing.  Run this script manually to fetch required images.

    The default download folder is `E:\SOC-9000\isos`.  You can override this by passing
    `-IsoDir` when invoking the script.

    NOTE: Direct download URLs are provided for convenience.  You should verify these links
    before running the script, and update them if the vendor releases new versions.  The
    script performs a basic content-type check after downloading but does not validate
    checksums.  For production use, you should verify the SHA256 sums against the official
    sources.
#>
[CmdletBinding()] param(
  [string]$IsoDir = "E:\\SOC-9000\\isos"
)
$ErrorActionPreference="Stop"; Set-StrictMode -Version Latest

function New-Dir($p){ if(!(Test-Path $p)){ New-Item -Type Directory -Path $p -Force | Out-Null } }

# Ensure destination directory exists
New-Dir $IsoDir

function Download-File {
    param(
        [Parameter(Mandatory)] [string]$Url,
        [Parameter(Mandatory)] [string]$OutFile,
        [string]$ExpectedContentType = ""
    )
    $fname = Split-Path $OutFile -Leaf
    if (Test-Path $OutFile) {
        Write-Host "[+] $fname already exists. Skipping download."
        return
    }
    Write-Host "[*] Downloading $fname..."
    try {
        # Some vendors require TLS 1.2
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $headers = @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)' }
        Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -Headers $headers
    } catch {
        Write-Warning "Failed to download ${Url}: $_"
        return
    }
    # Basic validation
    if ($ExpectedContentType) {
        try {
            $resp = Invoke-WebRequest -Uri $Url -Method Head -UseBasicParsing
            if ($resp.Headers['Content-Type'] -and $resp.Headers['Content-Type'] -notlike "*${ExpectedContentType}*") {
                Write-Warning "$fname downloaded but content-type mismatch: $($resp.Headers['Content-Type'])"
            }
        } catch {
            # ignore HEAD failures
        }
    }
    $size = (Get-Item $OutFile).Length / 1MB
    Write-Host "[+] Saved $fname ($([math]::Round($size,1)) MB)"
}

# Define download URLs
$downloads = @{
    "pfsense.iso" = @{
        urls = @(
            "https://nyifiles.pfsense.org/mirror/downloads/pfSense-CE-2.7.3-RELEASE-amd64.iso",
            "https://frafiles.pfsense.org/mirror/downloads/pfSense-CE-2.7.3-RELEASE-amd64.iso",
            "https://atxfiles.pfsense.org/mirror/downloads/pfSense-CE-2.7.3-RELEASE-amd64.iso"
        );
        type = "application/octet-stream"
    }
    "ubuntu-22.04.iso" = @{
        urls = @("https://releases.ubuntu.com/22.04.5/ubuntu-22.04.5-live-server-amd64.iso");
        type = "application/octet-stream"
    }
    "win11-eval.iso" = @{
        urls = @("https://software-download.microsoft.com/download/pr/Win11_23H2_English_x64v2.iso");
        type = "application/octet-stream"
    }
    "nessus_latest_amd64.deb" = @{
        urls = @("https://www.tenable.com/downloads/api/v1/public/pages/nessus/downloads/26139/download?i_agree_to_tenable_license_agreement=true");
        type = "application/x-debian-package"
    }
}

foreach ($item in $downloads.GetEnumerator()) {
    $dest = Join-Path $IsoDir $item.Key
    foreach ($url in $item.Value.urls) {
        if (Test-Path $dest) { break }
        Download-File -Url $url -OutFile $dest -ExpectedContentType $item.Value.type
    }
    if (!(Test-Path $dest)) {
        Write-Warning "$($item.Key) could not be downloaded from any mirror. Please download it manually."
    }
}

Write-Host "All downloads complete."

