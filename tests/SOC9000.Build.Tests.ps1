<#
.SYNOPSIS
    Pester tests for SOC9000.Build module

.DESCRIPTION
    Unit tests for Packer operations and build helpers.
#>

BeforeAll {
    $ModulePath = Join-Path $PSScriptRoot '..' 'modules' 'SOC9000.Build.psm1'
    Import-Module $ModulePath -Force
}

Describe 'SOC9000.Build Module' {
    Context 'Packer Discovery' {
        It 'Find-PackerExecutable should return null or valid path' {
            $result = Find-PackerExecutable
            if ($result) {
                Test-Path $result | Should -Be $true
                $result | Should -Match 'packer\.exe$'
            }
            else {
                $result | Should -BeNullOrEmpty
            }
        }
    }

    Context 'ISO Discovery' {
        It 'Find-IsoFile should return null for non-existent directory' {
            $result = Find-IsoFile -Directory 'C:\NonExistent' -Patterns @('*.iso')
            $result | Should -BeNullOrEmpty
        }

        It 'Find-IsoFile should find ISO in test directory' {
            $testDir = Join-Path $TestDrive 'isos'
            New-Item -ItemType Directory -Path $testDir -Force | Out-Null
            $testIso = Join-Path $testDir 'test-ubuntu-22.04.iso'
            New-Item -ItemType File -Path $testIso -Force | Out-Null

            $result = Find-IsoFile -Directory $testDir -Patterns @('ubuntu-*.iso', 'test-*.iso')
            $result | Should -Not -BeNullOrEmpty
            $result.FullName | Should -Be $testIso
        }

        It 'Find-IsoFile should return most recent ISO' {
            $testDir = Join-Path $TestDrive 'isos2'
            New-Item -ItemType Directory -Path $testDir -Force | Out-Null

            $iso1 = Join-Path $testDir 'ubuntu-22.04.1.iso'
            $iso2 = Join-Path $testDir 'ubuntu-22.04.2.iso'

            New-Item -ItemType File -Path $iso1 -Force | Out-Null
            Start-Sleep -Milliseconds 100
            New-Item -ItemType File -Path $iso2 -Force | Out-Null

            $result = Find-IsoFile -Directory $testDir -Patterns @('ubuntu-*.iso')
            $result.Name | Should -Be 'ubuntu-22.04.2.iso'
        }
    }

    Context 'Progress Display' {
        It 'Show-PackerProgress should not throw with valid parameters' {
            $logFile = Join-Path $TestDrive 'test.log'
            Set-Content -Path $logFile -Value 'Test log content'

            {
                Show-PackerProgress -LogPath $logFile -StartTime (Get-Date) -TimeoutMinutes 60
            } | Should -Not -Throw
        }
    }

    Context 'Artifact Verification' {
        It 'Wait-ForVMxArtifacts should timeout when artifacts not found' {
            $targets = @(
                @{ Name = 'Test'; Directory = 'C:\NonExistent'; Pattern = '*.vmx' }
            )

            {
                Wait-ForVMxArtifacts -Targets $targets -MaxWaitSeconds 2
            } | Should -Throw
        }

        It 'Wait-ForVMxArtifacts should find existing artifacts' {
            $testDir = Join-Path $TestDrive 'vm'
            New-Item -ItemType Directory -Path $testDir -Force | Out-Null
            $vmxFile = Join-Path $testDir 'test.vmx'
            New-Item -ItemType File -Path $vmxFile -Force | Out-Null

            $targets = @(
                @{ Name = 'Test'; Directory = $testDir; Pattern = '*.vmx' }
            )

            $result = Wait-ForVMxArtifacts -Targets $targets -MaxWaitSeconds 10
            $result['Test'] | Should -Be $vmxFile
        }
    }

    Context 'Packer Operations' {
        It 'Invoke-PackerInit should require valid template path' {
            $testLog = Join-Path $TestDrive 'init.log'
            $packer = Find-PackerExecutable

            if ($packer) {
                {
                    Invoke-PackerInit -TemplatePath 'C:\NonExistent\template.pkr.hcl' `
                        -PackerExe $packer -LogPath $testLog
                } | Should -Throw
            }
            else {
                Set-ItResult -Skipped -Because 'Packer not installed'
            }
        }
    }
}

AfterAll {
    Remove-Module SOC9000.Build -ErrorAction SilentlyContinue
}
