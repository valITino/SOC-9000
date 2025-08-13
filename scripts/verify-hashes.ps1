[CmdletBinding()]
param(
    [string]$IsoDir,
    [string]$ChecksumsPath,     # optional; auto-locate if omitted
    [switch]$Strict,            # if set, exit nonzero on mismatch/missing
    [string]$OutPath            # if provided, write actual hashes to this file
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-IsoDir {
    param([string]$Given)
    if ($Given) { return [IO.Path]::GetFullPath($Given) }
    # Try .env -> ISO_DIR
    $envPath = Join-Path (Split-Path -Parent $PSScriptRoot) '..\.env'
    if (Test-Path $envPath) {
        $line = Select-String -Path $envPath -Pattern '^\s*ISO_DIR=(.+)$' -ErrorAction SilentlyContinue
        if ($line) {
            $dir = $line.Matches.Value.Split('=')[1].Trim()
            if ($dir) { return [IO.Path]::GetFullPath($dir) }
        }
    }
    # Default fallback
    return [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $PSScriptRoot) '..\isos'))
}

function Find-ChecksumsFile {
    param([string]$IsoDir,[string]$Given)
    if ($Given) { return [IO.Path]::GetFullPath($Given) }
    $c1 = Join-Path $IsoDir 'checksums.txt'
    if (Test-Path $c1) { return $c1 }
    $root = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $PSScriptRoot) '..'))
    $c2 = Join-Path $root 'checksums.txt'
    if (Test-Path $c2) { return $c2 }
    return $null
}

function Get-ActualHashes {
    param(
        [string]$IsoDir,
        [string[]]$Candidates,
        [hashtable]$AltPatterns
    )
    $results = @()
    $files = Get-ChildItem -Path $IsoDir -File -ErrorAction SilentlyContinue
    foreach ($name in $Candidates) {
        $path = Join-Path $IsoDir $name
        if (-not (Test-Path $path) -and $AltPatterns.ContainsKey($name)) {
            $pat = $AltPatterns[$name]
            $match = $files | Where-Object { $_.Name -match $pat } | Select-Object -First 1
            if ($match) { $path = $match.FullName }
        }

        if (Test-Path $path) {
            $h = Get-FileHash -Algorithm SHA256 -Path $path
            $results += [pscustomobject]@{
                File = $name
                Path = $path
                SHA256 = $h.Hash.ToUpperInvariant()
                Exists = $true
            }
        } else {
            $results += [pscustomobject]@{
                File = $name
                Path = $path
                SHA256 = ''
                Exists = $false
            }
        }
    }
    return $results
}

function Parse-Checksums {
    param([string]$Path)
    # Supported formats (case-insensitive):
    # 1) sha256  filename.ext            (common)
    # 2) sha256 *filename.ext            (GNU 'sha256sum' style)
    # 3) filename.ext  sha256            (we also accept this)
    # Ignore blank lines and lines starting with '#' or ';'
    $map = @{}
    $lines = Get-Content -Path $Path -ErrorAction Stop
    foreach ($raw in $lines) {
        $line = $raw.Trim()
        if (-not $line) { continue }
        if ($line.StartsWith('#') -or $line.StartsWith(';')) { continue }

        $hash = $null; $file = $null

        # Pattern 1/2: ^([0-9a-f]{64})\s+\*?(.+)$
        $m1 = [regex]::Match($line, '^([0-9A-Fa-f]{64})\s+\*?(.+)$')
        if ($m1.Success) {
            $hash = $m1.Groups[1].Value.ToUpperInvariant()
            $file = $m1.Groups[2].Value.Trim()
        } else {
            # Pattern 3: ^(.+?)\s+([0-9a-f]{64})$
            $m2 = [regex]::Match($line, '^(.+?)\s+([0-9A-Fa-f]{64})$')
            if ($m2.Success) {
                $file = $m2.Groups[1].Value.Trim()
                $hash = $m2.Groups[2].Value.ToUpperInvariant()
            }
        }

        if ($file -and $hash) {
            $map[$file] = $hash
        }
    }
    return $map
}

function Write-Table {
    param($rows)
    $widthFile = ($rows | ForEach-Object { $_.File.Length } | Measure-Object -Maximum).Maximum
    if (-not $widthFile -or $widthFile -lt 12) { $widthFile = 12 }
    foreach ($r in $rows) {
        $status = if ($r.Status) { $r.Status } else { '' }
        "{0,-$widthFile}  {1}  {2}" -f $r.File, $r.SHA256, $status
    }
}

# --- Main ---
$IsoDir = Resolve-IsoDir -Given $IsoDir
Write-Host "ISO dir: $IsoDir" -ForegroundColor Cyan
if (-not (Test-Path $IsoDir)) { Write-Error "Missing folder: $IsoDir"; exit 1 }

# Known default filenames
$DefaultFiles = @(
  'ubuntu-22.04.iso',
  'pfsense.iso',
  'win11-eval.iso',
  'nessus_latest_amd64.deb'
)

# Patterns to locate vendor-named files when canonical names are absent
$AltPatterns = @{
    'ubuntu-22.04.iso'       = '(?i)^ubuntu-22\.04.*\.iso$'
    'pfsense.iso'            = '(?i)(pfsense|netgate).*\.iso$'
    'win11-eval.iso'         = '(?i).*win(dows)?[^\\w]*11.*\.iso$'
    'nessus_latest_amd64.deb' = '(?i)^nessus.*amd64.*\.deb$'
}

$ChecksumsPath = Find-ChecksumsFile -IsoDir $IsoDir -Given $ChecksumsPath

# Gather actual file hashes first so we can auto-consume vendor *.sha256 files
$Actual = Get-ActualHashes -IsoDir $IsoDir -Candidates $DefaultFiles -AltPatterns $AltPatterns

if ($OutPath) {
    # Emit actual hashes file for whatever exists
    $lines = @()
    foreach ($a in $Actual) {
        if ($a.Exists) {
            $lines += ("{0}  {1}" -f $a.SHA256, $a.File)
        } else {
            $lines += ("# (missing)  {0}" -f $a.File)
        }
    }
    Set-Content -Path $OutPath -Value $lines -Encoding ASCII
    Write-Host "Wrote actual hashes to: $OutPath" -ForegroundColor Green
    exit 0
}

# Load expected hashes from checksums.txt if available
if (-not $ChecksumsPath) {
    # Create a template next to ISO dir and instruct the user
    $tmpl = Join-Path $IsoDir 'checksums.txt'
    $tplLines = @(
        '# checksums.txt - SHA256 hashes for SOC-9000 downloads',
        '# Format (either is accepted):',
        '#   <SHA256>  <filename>',
        '#   <filename>  <SHA256>',
        '# Lines starting with # or ; are ignored.',
        '',
        '# Example (replace the hash with the vendor-provided value):',
        '# 0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF  ubuntu-22.04.iso',
        '# 89ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF01234567  pfsense.iso',
        '# win11-eval.iso  FEDCBA9876543210FEDCBA9876543210FEDCBA9876543210FEDCBA9876543210',
        '# nessus_latest_amd64.deb  76543210FEDCBA9876543210FEDCBA9876543210FEDCBA9876543210FEDCBA98'
    )
    Set-Content -Path $tmpl -Value $tplLines -Encoding ASCII
    Write-Warning "No checksums file found. A template was created at: $tmpl"
    Write-Host  "Tip: Generate actual hashes to fill it:" -ForegroundColor Yellow
    Write-Host  "  pwsh -File scripts/verify-hashes.ps1 -OutPath $tmpl" -ForegroundColor Yellow
    exit 0
}

Write-Host "Checksums file: $ChecksumsPath" -ForegroundColor Cyan
$Expect = Parse-Checksums -Path $ChecksumsPath

# Supplement expected hashes with vendor-provided *.sha256 files
foreach ($a in $Actual) {
    if (-not $a.Exists) { continue }
    $shaCandidates = @("$($a.Path).sha256","$($a.Path).sha256.txt") +
        (Get-ChildItem -Path (Split-Path $a.Path) -File -ErrorAction SilentlyContinue |
         Where-Object { $_.Name -like "$(Split-Path -Leaf $a.Path)*.sha256*" }) | % { $_.FullName }
    $sha = $shaCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($sha) {
        $line = Select-String -Path $sha -Pattern '[0-9A-Fa-f]{64}' | Select-Object -First 1
        if ($line) { $Expect[$a.File] = $line.Matches[0].Value.ToUpperInvariant() }
    }
}

# Build candidate list from expected hashes and defaults
$AllNames = New-Object System.Collections.Generic.HashSet[string]
foreach ($k in $Expect.Keys) { [void]$AllNames.Add($k) }
foreach ($d in $DefaultFiles) { [void]$AllNames.Add($d) }
$Candidates = @($AllNames)

# Recompute actual hashes with full candidate list
$Actual = Get-ActualHashes -IsoDir $IsoDir -Candidates $Candidates -AltPatterns $AltPatterns

# Compare
$rows = @()
$missing = 0; $mismatch = 0; $ok = 0
foreach ($a in $Actual) {
    $exp = $null
    if ($Expect.ContainsKey($a.File)) { $exp = $Expect[$a.File] }
    $status = ''
    if (-not $a.Exists) {
        $status = 'MISSING'
        $missing++
    } elseif ($exp) {
        if ($exp -eq $a.SHA256) { $status = 'OK'; $ok++ }
        else { $status = 'MISMATCH'; $mismatch++ }
    } else {
        $status = 'NO-EXPECTED'  # not listed in checksums
    }
    $rows += [pscustomobject]@{
        File = $a.File
        SHA256 = if ($a.Exists) { $a.SHA256 } else { '' }
        Status = $status
    }
}

Write-Host ""
Write-Table -rows $rows | Out-Host
Write-Host ""

Write-Host ("Summary: OK={0}  MISMATCH={1}  MISSING={2}  TOTAL={3}" -f $ok,$mismatch,$missing,$rows.Count) -ForegroundColor Cyan

if ($Strict) {
    if ($mismatch -gt 0 -or $missing -gt 0) { exit 2 }
}
exit 0
