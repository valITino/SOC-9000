# --- config ---
$srcIso  = 'E:\SOC-9000-Install\isos\Win11_24H2_noprompt_autounattend_uefi.iso'
$work    = 'E:\VMs\Win-NoPrompt src'
$answer  = 'C:\Users\liamo\Downloads\autounattend.xml'
$outIso  = 'E:\SOC-9000-Install\isos\Win11_24H2_noprompt_autounattend_uefi.iso'
$label   = 'WIN11_24H2_NOPROMPT'
$oscdimg = 'C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe'
# -------------

# Admin check
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
         ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  throw "Run this script in an elevated PowerShell (Run as Administrator)."
}

# Prepare work dir
New-Item -Force -ItemType Directory -Path $work | Out-Null

# Mount ISO and mirror contents
$img = Mount-DiskImage -ImagePath $srcIso -PassThru
$vol = ($img | Get-Volume).DriveLetter + ':'
robocopy "$vol\" "$work\" /MIR | Out-Null
Dismount-DiskImage -ImagePath $srcIso

# IMPORTANT: remove read-only/system/hidden attributes copied from ISO
attrib -r -s -h (Join-Path $work '*') /s /d

# Place answer file on media (root + sources)
Copy-Item -Force $answer (Join-Path $work 'autounattend.xml')
Copy-Item -Force $answer (Join-Path $work 'sources\autounattend.xml')
Copy-Item -Force $answer (Join-Path $work 'sources\unattend.xml')

# Clean up any stale mount and prep mount/scratch dirs
& dism /English /Cleanup-Mountpoints | Out-Null
$mountDir  = Join-Path $work 'mount'
$scratch   = Join-Path $work 'scratch'
New-Item -Force -ItemType Directory -Path $mountDir,$scratch | Out-Null

# Mount boot.wim (index 2 = Windows Setup) READ-WRITE
& dism /English /Mount-Image /ImageFile:"$work\sources\boot.wim" /Index:2 /MountDir:"$mountDir" /ScratchDir:"$scratch" | Out-Null

try {
  # Put answer file inside WinPE so it is X:\autounattend.xml
  Copy-Item -Force $answer (Join-Path $mountDir 'autounattend.xml')

  # Optional: tiny log marker to prove WinPE started
  $startnet = Join-Path $mountDir 'Windows\System32\startnet.cmd'
  Set-Content -Encoding ASCII -Path $startnet -Value "@echo off`r`nwpeinit`r`necho Started > X:\pe-started.log"

  # Force WinPE to launch Setup with our answer file immediately
  $winpeshl = Join-Path $mountDir 'Windows\System32\winpeshl.ini'
  $ini = @'
[LaunchApps]
%SYSTEMDRIVE%\setup.exe,/unattend:%SYSTEMDRIVE%\autounattend.xml
'@
  Set-Content -Encoding ASCII -Path $winpeshl -Value $ini
}
catch {
  # If anything above failed, discard changes
  & dism /English /Unmount-Image /MountDir:"$mountDir" /Discard | Out-Null
  throw
}

# Commit and unmount
& dism /English /Unmount-Image /MountDir:"$mountDir" /Commit | Out-Null
Remove-Item -Recurse -Force $mountDir,$scratch

# Rebuild ISO with **no-prompt** UEFI boot image
$efiBoot  = Join-Path $work 'efi\microsoft\boot\efisys_noprompt.bin'
$biosBoot = Join-Path $work 'boot\etfsboot.com'

& "$oscdimg" -m -o -u2 -udfver102 -l$label `
  -bootdata:2#p0,e,b"$biosBoot"#pEF,e,b"$efiBoot" `
  "$work" "$outIso"

Write-Host "ISO ready: $outIso"


Get-FileHash 'E:\SOC-9000-Install\isos\Win11_24H2_noprompt_autounattend_uefi.iso' -Algorithm SHA256

Write-Host "DONE FOR GOOD!"