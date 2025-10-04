# Tags: unit
[CmdletBinding()] param()
Describe "VMnet profile generator" -Tag 'unit' {
  It "generates expected content from a sample env" {
    $here = $PSScriptRoot
    $repo = Split-Path $here -Parent
    $gen  = Join-Path $repo 'scripts/generate-vmnet-profile.ps1'
    $tmpEnv = Join-Path ([IO.Path]::GetTempPath()) 'soc9000-test.env'
    @"
VMNET8_SUBNET=192.168.186.0
VMNET8_MASK=255.255.255.0
VMNET8_HOSTIP=192.168.186.1
VMNET8_GATEWAY=192.168.186.2
VMNET20_SUBNET=172.22.10.0
VMNET21_SUBNET=172.22.20.0
VMNET22_SUBNET=172.22.30.0
VMNET23_SUBNET=172.22.40.0
HOSTONLY_MASK=255.255.255.0
HOSTONLY_VMNET_IDS=20,21,22,23
"@ | Set-Content -Path $tmpEnv -Encoding ASCII
    $out = Join-Path ([IO.Path]::GetTempPath()) 'soc9000-vmnet-import.txt'
    $text = . $gen -EnvPath $tmpEnv -OutFile $out -PassThru
    $expected = @"
add adapter vmnet20
add vnet vmnet20
set vnet vmnet20 addr 172.22.10.0
set vnet vmnet20 mask 255.255.255.0
set adapter vmnet20 addr 172.22.10.1
update adapter vmnet20

add adapter vmnet21
add vnet vmnet21
set vnet vmnet21 addr 172.22.20.0
set vnet vmnet21 mask 255.255.255.0
set adapter vmnet21 addr 172.22.20.1
update adapter vmnet21

add adapter vmnet22
add vnet vmnet22
set vnet vmnet22 addr 172.22.30.0
set vnet vmnet22 mask 255.255.255.0
set adapter vmnet22 addr 172.22.30.1
update adapter vmnet22

add adapter vmnet23
add vnet vmnet23
set vnet vmnet23 addr 172.22.40.0
set vnet vmnet23 mask 255.255.255.0
set adapter vmnet23 addr 172.22.40.1
update adapter vmnet23
"@ -replace "`r`n","`n"
    ($text -replace "`r`n","`n").TrimEnd() | Should -BeExactly $expected
    Test-Path $out | Should -BeTrue
  }
}
