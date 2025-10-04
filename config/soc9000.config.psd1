@{
    # SOC-9000 Central Configuration
    # Version: 1.0.0
    # Description: Central configuration for SOC-9000 Lab automation

    # ==================== VERSION INFO ====================
    Version     = '1.0.0'
    Description = 'SOC-9000 Lab Automation Configuration'

    # ==================== PATHS ====================
    Paths       = @{
        # Install root (override via environment or .env)
        # Default: E:\SOC-9000-Install (if E: exists) or C:\SOC-9000-Install
        InstallRoot = 'E:\SOC-9000-Install'

        # ISO directory (relative to InstallRoot unless overridden)
        IsoDirectory = 'isos'

        # VM output directory
        VMDirectory = 'VMs'

        # Logs directory
        LogDirectory = 'logs'

        # State directory (for artifact tracking)
        StateDirectory = 'state'

        # Cache directory (for Packer)
        CacheDirectory = 'cache'

        # Keys directory (SSH keys)
        KeysDirectory = 'keys'
    }

    # ==================== BUILD SETTINGS ====================
    Build       = @{
        # Packer settings
        Packer            = @{
            TimeoutMinutes = @{
                Ubuntu  = 45
                Windows = 120
                Nessus  = 30
                PfSense = 30
            }
            DefaultHeadless   = $true
            HttpPort          = 8800
        }

        # VM names and output directories (relative to VMDirectory)
        VMNames           = @{
            Ubuntu  = 'Ubuntu'
            Windows = 'Windows'
            Nessus  = 'Nessus'
            PfSense = 'PfSense'
        }

        # SSH settings
        SSH               = @{
            KeyType            = 'ed25519'
            DefaultUbuntuUser  = 'labadmin'
        }
    }

    # ==================== ISO SETTINGS ====================
    ISOs        = @{
        # ISO filename patterns for discovery
        Patterns = @{
            Ubuntu  = @('ubuntu-22.04*.iso', 'ubuntu-22.04*server*.iso')
            Windows = @('Win*11*.iso', 'Windows*11*.iso', 'en-us_windows_11*.iso')
            Nessus  = @('Nessus-*.iso', 'nessus-*.iso')
            PfSense = @('pfSense-*.iso', 'pfsense-*.iso')
        }
    }

    # ==================== NETWORK SETTINGS ====================
    Network     = @{
        # VMnet8 (NAT)
        VMnet8          = @{
            Subnet     = '192.168.8.0'
            Netmask    = '255.255.255.0'
            Gateway    = '192.168.8.2'
            DHCPStart  = '192.168.8.128'
            DHCPEnd    = '192.168.8.254'
            HostIP     = '192.168.8.1'
        }

        # VMnet2 (Host-Only / Private)
        VMnet2          = @{
            Subnet     = '192.168.2.0'
            Netmask    = '255.255.255.0'
            Gateway    = '192.168.2.1'
            DHCPStart  = '192.168.2.128'
            DHCPEnd    = '192.168.2.254'
            HostIP     = '192.168.2.1'
        }

        # Firewall rules
        FirewallRules   = @(
            @{
                DisplayName = 'Packer HTTP Any (8800)'
                Direction   = 'Inbound'
                Action      = 'Allow'
                Protocol    = 'TCP'
                LocalPort   = 8800
                Profile     = 'Private'
            }
        )
    }

    # ==================== TOOLS & PREREQUISITES ====================
    Tools       = @{
        Required = @{
            PowerShell7 = @{
                WinGetId    = 'Microsoft.PowerShell'
                DisplayName = 'PowerShell 7'
                MinVersion  = '7.2.0'
            }
            Packer      = @{
                WinGetId    = 'Hashicorp.Packer'
                DisplayName = 'HashiCorp Packer'
            }
            Kubectl     = @{
                WinGetId    = 'Kubernetes.kubectl'
                DisplayName = 'kubectl'
            }
            Git         = @{
                WinGetId    = 'Git.Git'
                DisplayName = 'Git'
            }
            TigerVNC    = @{
                WinGetId    = 'TigerVNC.TigerVNC'
                DisplayName = 'TigerVNC Viewer'
            }
        }

        Optional = @{
            VMwareWorkstation = @{
                DisplayName = 'VMware Workstation Pro'
                MinVersion  = 17
            }
        }
    }

    # ==================== SYSTEM REQUIREMENTS ====================
    Requirements = @{
        MinimumRAM_GB     = 32
        MinimumStorage_GB = 800
        MinimumFreeDisk_GB = 50
        RequiresVirtualization = $true
    }

    # ==================== FEATURE FLAGS ====================
    Features    = @{
        EnableTelemetry    = $false
        EnableVerboseLogging = $true
        AutoCleanupCache   = $true
        ValidateChecksums  = $false
    }
}
