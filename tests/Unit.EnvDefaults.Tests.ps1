# Tags: unit
[CmdletBinding()] param()
BeforeAll {
  $repo = Split-Path $PSScriptRoot -Parent
  $envExample = Join-Path $repo '.env.example'
  if (-not (Test-Path $envExample)) { throw ".env.example missing at repo root" }
  $content = Get-Content $envExample -Raw
  $script:globals = @(
    'LAB_ROOT','REPO_ROOT','ISO_DIR','ARTIFACTS_DIR','TEMP_DIR',
    'VMNET8_SUBNET','VMNET8_MASK','VMNET8_HOSTIP','VMNET8_GATEWAY',
    'VMNET20_SUBNET','VMNET21_SUBNET','VMNET22_SUBNET','VMNET23_SUBNET','HOSTONLY_MASK',
    'NESSUS_DEB','BACKUP_DIR','SNAPSHOT_RETENTION'
  )
  $script:content = $content
}
Describe ".env.example baseline" -Tag 'unit' {
  It "contains the required keys" {
    foreach($k in $script:globals){ $script:content | Should -Match ("(?m)^$k=") }
  }
}
