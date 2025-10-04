<#
.SYNOPSIS
    Pester tests for SOC9000.Utils module

.DESCRIPTION
    Unit tests for logging, validation, paths, and utility functions.
#>

BeforeAll {
    $ModulePath = Join-Path $PSScriptRoot '..' 'modules' 'SOC9000.Utils.psm1'
    Import-Module $ModulePath -Force
}

Describe 'SOC9000.Utils Module' {
    Context 'Logging Functions' {
        It 'Write-InfoLog should not throw' {
            { Write-InfoLog -Message 'Test message' } | Should -Not -Throw
        }

        It 'Write-SuccessLog should not throw' {
            { Write-SuccessLog -Message 'Test success' } | Should -Not -Throw
        }

        It 'Write-WarnLog should not throw' {
            { Write-WarnLog -Message 'Test warning' } | Should -Not -Throw
        }

        It 'Write-ErrorLog should not throw' {
            { Write-ErrorLog -Message 'Test error' } | Should -Not -Throw
        }

        It 'Write-Banner should not throw' {
            { Write-Banner -Title 'Test Banner' } | Should -Not -Throw
        }

        It 'Write-Panel should not throw' {
            { Write-Panel -Title 'Test Panel' -Lines @('Line 1', 'Line 2') } | Should -Not -Throw
        }
    }

    Context 'Environment Configuration' {
        It 'Get-DotEnvConfig should return hashtable for non-existent file' {
            $result = Get-DotEnvConfig -Path 'C:\nonexistent\.env'
            $result | Should -BeOfType [hashtable]
            $result.Count | Should -Be 0
        }

        It 'Get-DotEnvConfig should parse valid .env file' {
            $tempEnv = Join-Path $TestDrive '.env'
            Set-Content -Path $tempEnv -Value "KEY1=value1`nKEY2=value2"

            $result = Get-DotEnvConfig -Path $tempEnv
            $result['KEY1'] | Should -Be 'value1'
            $result['KEY2'] | Should -Be 'value2'
        }

        It 'Get-DotEnvConfig should ignore comments and blank lines' {
            $tempEnv = Join-Path $TestDrive '.env'
            Set-Content -Path $tempEnv -Value "# Comment`n`nKEY=value"

            $result = Get-DotEnvConfig -Path $tempEnv
            $result.Count | Should -Be 1
            $result['KEY'] | Should -Be 'value'
        }
    }

    Context 'Path Utilities' {
        It 'Confirm-Directory should create directory if not exists' {
            $testDir = Join-Path $TestDrive 'newdir'
            Confirm-Directory -Path $testDir
            Test-Path $testDir | Should -Be $true
        }

        It 'Confirm-Directory should not fail if directory exists' {
            $testDir = Join-Path $TestDrive 'existingdir'
            New-Item -ItemType Directory -Path $testDir -Force | Out-Null
            { Confirm-Directory -Path $testDir } | Should -Not -Throw
        }

        It 'Get-RepositoryRoot should return a valid path' {
            $result = Get-RepositoryRoot
            $result | Should -Not -BeNullOrEmpty
            Test-Path $result | Should -Be $true
        }
    }

    Context 'Validation Functions' {
        It 'Assert-FileExists should not throw for existing file' {
            $testFile = Join-Path $TestDrive 'testfile.txt'
            New-Item -ItemType File -Path $testFile -Force | Out-Null
            { Assert-FileExists -Path $testFile -Label 'Test File' } | Should -Not -Throw
        }

        It 'Assert-FileExists should throw for non-existent file' {
            $testFile = Join-Path $TestDrive 'nonexistent.txt'
            { Assert-FileExists -Path $testFile -Label 'Test File' } | Should -Throw
        }

        It 'Assert-CommandExists should not throw for existing command' {
            { Assert-CommandExists -CommandName 'powershell' } | Should -Not -Throw
        }

        It 'Assert-CommandExists should throw for non-existent command' {
            { Assert-CommandExists -CommandName 'nonexistentcommand123' } | Should -Throw
        }
    }

    Context 'Retry Logic' {
        It 'Invoke-WithRetry should succeed on first attempt' {
            $result = Invoke-WithRetry -ScriptBlock { return 'success' } -MaxAttempts 3
            $result | Should -Be 'success'
        }

        It 'Invoke-WithRetry should retry on failure' {
            $script:attempts = 0
            $result = Invoke-WithRetry -ScriptBlock {
                $script:attempts++
                if ($script:attempts -lt 2) { throw 'fail' }
                return 'success'
            } -MaxAttempts 3 -InitialDelaySeconds 0

            $result | Should -Be 'success'
        }

        It 'Invoke-WithRetry should throw after max attempts' {
            {
                Invoke-WithRetry -ScriptBlock {
                    throw 'always fail'
                } -MaxAttempts 2 -InitialDelaySeconds 0
            } | Should -Throw
        }
    }

    Context 'Administrator Functions' {
        It 'Test-IsAdministrator should return boolean' {
            $result = Test-IsAdministrator
            $result | Should -BeOfType [bool]
        }
    }
}

AfterAll {
    Remove-Module SOC9000.Utils -ErrorAction SilentlyContinue
}
