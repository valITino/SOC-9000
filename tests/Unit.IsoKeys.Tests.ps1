# Tags: unit
[CmdletBinding()] param()
Describe "ISO key detection" -Tag 'unit' {
  It "detects ISO_* and NESSUS_DEB entries" {
    function Get-RequiredIsosLocal {
      param([hashtable]$EnvMap,[string]$IsoDir)
      $pairs = @()
      foreach ($key in $EnvMap.Keys) {
        if ($key -like 'ISO_*' -or $key -eq 'NESSUS_DEB') {
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
      'OTHER_KEY' = 'ignored.txt'
    }
    $isoDir = if ($IsWindows) { 'C:\isos' } else { '/isos' }
    $pairs = Get-RequiredIsosLocal -EnvMap $envMap -IsoDir $isoDir
    ($pairs | Measure-Object).Count | Should -Be 3
    ($pairs | Where-Object Key -eq 'ISO_UBUNTU').FullPath | Should -BeExactly (Join-Path $isoDir 'ubuntu-24.04.1-live-server-amd64.iso')
    ($pairs | Where-Object Key -eq 'NESSUS_DEB').FileName | Should -BeExactly 'Nessus-10.8.1-ubuntu1404_amd64.deb'
  }
}

