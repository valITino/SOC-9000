$src  = 'E:\VMs\Win-NoPrompt src'
$dst  = 'E:\VMs\Win11_24H2_noprompt_autounattend_uefi.iso'
$oscd = 'C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe'
$efi  = Join-Path $src 'efi\microsoft\boot\efisys_noprompt.bin'
if (!(Test-Path $efi)) { throw "Not found: $efi" }
$boot = ('-bootdata:1#pEF,e,b"{0}"' -f $efi)
& $oscd -m -o -u2 -udfver102 -lWIN11_24H2_NOPROMPT_AUTOUNATTEND $boot $src $dst
Get-FileHash 'E:\SOC-9000-Install\isos\Win11_24H2_noprompt_autounattend_uefi.iso' -Algorithm SHA256
Write-Host "Done. Check it out in E:\VMs"