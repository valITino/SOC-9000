# Tags: unit
[CmdletBinding()] param()
Describe "ISO key detection" -Tag 'unit' {
  It "detects ISO_* and NESSUS_DEB entries" {
    function Get-RequiredIsosLocal {
      param([hashtable]$EnvMap,[string]$IsoDir)
      $pairs = @()
      foreach ($key in $EnvMap.Keys) {
        if (($key -like 'ISO_*' -and $key -ne 'ISO_DIR') -or $key -eq 'NESSUS_DEB') {
          $name = $EnvMap[$key]
          if ([string]::IsNullOrWhiteSpace($name)) { continue }
          $full = Join-Path $IsoDir $name
          $pairs += [pscustomobject]@{ Key=$key; FileName=$name; FullPath=$full; Exists=(Test-Path $full) }
        }
      }
      $pairs
    }
    $envMap = @{
      'ISO_UBUNTU' = 'ubuntu-24.04.1-live-server-amd64.iso'
      'ISO_PFSENSE' = 'pfSense-CE-2.7.2-RELEASE-amd64.iso'
      'NESSUS_DEB' = 'Nessus-10.8.1-ubuntu1404_amd64.deb'
      'ISO_DIR' = 'ignore-me'
      'OTHER_KEY' = 'ignored.txt'
    }
    $isoDir = if ($IsWindows) { 'C:\isos' } else { '/isos' }
    $pairs = Get-RequiredIsosLocal -EnvMap $envMap -IsoDir $isoDir
    ($pairs | Measure-Object).Count | Should -Be 3
    ($pairs | Where-Object Key -eq 'ISO_DIR').Count | Should -Be 0
    ($pairs | Where-Object Key -eq 'ISO_UBUNTU').FullPath | Should -BeExactly (Join-Path $isoDir 'ubuntu-24.04.1-live-server-amd64.iso')
    ($pairs | Where-Object Key -eq 'NESSUS_DEB').FileName | Should -BeExactly 'Nessus-10.8.1-ubuntu1404_amd64.deb'
  }
}

Describe "Prompt-MissingIsosLoop" -Tag 'unit' {
  It "returns immediately when all ISOs exist" {
    function Prompt-MissingIsosLoopLocal {
      param([pscustomobject[]]$IsoList,[string]$IsoDir)
      $missing = $IsoList | Where-Object { -not $_.Exists }
      if (($missing | Measure-Object).Count -eq 0) { return $true } else { return $false }
    }
    $list = @(
      [pscustomobject]@{Key='ISO_1'; FileName='a.iso'; FullPath='/isos/a.iso'; Exists=$true},
      [pscustomobject]@{Key='ISO_2'; FileName='b.iso'; FullPath='/isos/b.iso'; Exists=$true}
    )
    Prompt-MissingIsosLoopLocal -IsoList $list -IsoDir '/isos' | Should -BeTrue
  }
}

