# Tags: integration
[CmdletBinding()] param()
function Find-VNetLib {
  foreach($p in @(
    "C:\Program Files (x86)\VMware\VMware Workstation\vnetlib64.exe",
    "C:\Program Files\VMware\VMware Workstation\vnetlib64.exe"
  )){ if (Test-Path $p) { return $p } }
  $null
}
Describe "VMware presence and non-destructive ops" -Tag 'integration' {
  It "finds vnetlib64.exe or skips" {
    $v = Find-VNetLib
    if (-not $v) { Set-ItResult -Skipped -Because "vnetlib64.exe not present"; return }
    Test-Path $v | Should -BeTrue
  }
  It "exports current profile (non-destructive) if vnetlib64.exe present" {
    $v = Find-VNetLib
    if (-not $v) { Set-ItResult -Skipped -Because "vnetlib64.exe not present"; return }
    $tmp = Join-Path $env:TEMP 'soc9000-export.txt'
    & $v -- export $tmp
    $LASTEXITCODE | Should -Be 0
    Test-Path $tmp | Should -BeTrue
  }
  It "optionally imports generated profile when SOC9000_ALLOW_IMPORT_IN_TESTS=1" {
    $v = Find-VNetLib
    if (-not $v) { Set-ItResult -Skipped -Because "vnetlib64.exe not present"; return }
    if ($env:SOC9000_ALLOW_IMPORT_IN_TESTS -ne '1') { Set-ItResult -Skipped -Because "import not enabled"; return }
    $repo = Split-Path $PSScriptRoot -Parent
    $gen  = Join-Path $repo 'scripts\generate-vmnet-profile.ps1'
    $out = Join-Path $env:TEMP 'soc9000-vmnet-import.txt'
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $gen -OutFile $out
    & $v -- stop dhcp; & $v -- stop nat
    & $v -- import $out; $LASTEXITCODE | Should -Be 0
    & $v -- start dhcp; & $v -- start nat
  }
}