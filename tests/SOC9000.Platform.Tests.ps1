<#
.SYNOPSIS
    Pester tests for SOC9000.Platform module

.DESCRIPTION
    Unit tests for OS checks, prerequisites, and tool installers.
#>

BeforeAll {
    $ModulePath = Join-Path $PSScriptRoot '..' 'modules' 'SOC9000.Platform.psm1'
    Import-Module $ModulePath -Force
}

Describe 'SOC9000.Platform Module' {
    Context 'PowerShell Detection' {
        It 'Get-PreferredShell should return a shell name' {
            $result = Get-PreferredShell
            $result | Should -BeIn @('pwsh', 'powershell')
        }

        It 'Test-PowerShell7Available should return boolean' {
            $result = Test-PowerShell7Available
            $result | Should -BeOfType [bool]
        }

        It 'Test-PowerShell7Available should be true in PS 7+' {
            if ($PSVersionTable.PSVersion.Major -ge 7) {
                Test-PowerShell7Available | Should -Be $true
            }
        }
    }

    Context 'Pending Reboot Detection' {
        It 'Test-PendingReboot should return boolean' {
            $result = Test-PendingReboot
            $result | Should -BeOfType [bool]
        }

        It 'Test-PendingReboot should not throw' {
            { Test-PendingReboot } | Should -Not -Throw
        }
    }

    Context 'VMware Detection' {
        It 'Get-VMwareWorkstationVersion should return string or null' {
            $result = Get-VMwareWorkstationVersion
            if ($result) {
                $result | Should -BeOfType [string]
            }
            else {
                $result | Should -BeNullOrEmpty
            }
        }

        It 'Test-VMwareWorkstationVersion should return boolean' {
            $result = Test-VMwareWorkstationVersion -MinimumVersion 17
            $result | Should -BeOfType [bool]
        }
    }

    Context 'WinGet Availability' {
        It 'Test-WinGetAvailable should return boolean' {
            $result = Test-WinGetAvailable
            $result | Should -BeOfType [bool]
        }
    }

    Context 'WSL Management' {
        It 'Test-WSLEnabled should return boolean' {
            $result = Test-WSLEnabled
            $result | Should -BeOfType [bool]
        }

        It 'Test-WSLEnabled should not throw' {
            { Test-WSLEnabled } | Should -Not -Throw
        }
    }

    Context 'Package Installation' {
        It 'Install-PackageViaWinGet should handle non-existent package gracefully' {
            if (Test-WinGetAvailable) {
                $result = Install-PackageViaWinGet -PackageId 'NonExistent.Package.12345' `
                    -DisplayName 'Test Package'
                $result | Should -BeOfType [bool]
            }
            else {
                Set-ItResult -Skipped -Because 'WinGet not available'
            }
        }
    }
}

AfterAll {
    Remove-Module SOC9000.Platform -ErrorAction SilentlyContinue
}
