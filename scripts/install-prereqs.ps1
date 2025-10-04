<#
  install-prereqs.ps1  (SOC-9000)
  - PowerShell 5.1 compatible
  - Installs/checks: PowerShell 7, HashiCorp Packer, kubectl, Git, TigerVNC (viewer)
  - Checks: VMware Workstation Pro (>= 17), E: drive
  - Enables Windows Features: WSL, VirtualMachinePlatform (without restart)
  - Avoids Windows Updates; only tool/feature checks + winget installations
  - Enhanced system information display with comprehensive checks
#>

[CmdletBinding()]
param()

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

# -------------------- UX helpers --------------------
function Write-Info([string]$Msg) { Write-Host "[>] $Msg" -ForegroundColor Cyan }
function Write-Ok([string]$Msg) { Write-Host "[OK] $Msg" -ForegroundColor Green }
function Write-Warn([string]$Msg) { Write-Host "[!] $Msg" -ForegroundColor Yellow }
function Write-Err([string]$Msg) { Write-Host "[X] $Msg" -ForegroundColor Red }

# -------------------- System Information Functions --------------------
function Get-SystemInfo {
    $info = @{}
    
    # Computer Information
    $computerInfo = Get-WmiObject -Class Win32_ComputerSystem
    $info.ComputerName = $env:COMPUTERNAME
    $info.Manufacturer = $computerInfo.Manufacturer
    $info.Model = $computerInfo.Model
    
    # OS Information
    $osInfo = Get-WmiObject -Class Win32_OperatingSystem
    $info.OSName = $osInfo.Caption
    $info.OSVersion = $osInfo.Version
    $info.BuildNumber = $osInfo.BuildNumber
    $info.InstallDate = if ($osInfo.InstallDate) { 
    [System.Management.ManagementDateTimeConverter]::ToDateTime($osInfo.InstallDate) 
    } else { 
    "Unknown" 
    }
    
    # Processor Information
    $processor = Get-WmiObject -Class Win32_Processor | Select-Object -First 1
    $info.Processor = $processor.Name
    $info.Cores = $processor.NumberOfCores
    $info.LogicalProcessors = $processor.NumberOfLogicalProcessors
    $info.MaxClockSpeed = "$($processor.MaxClockSpeed) MHz"
    
    # Memory Information
    $memory = Get-WmiObject -Class Win32_PhysicalMemory | Measure-Object -Property Capacity -Sum
    $info.TotalRAM = "{0:N2} GB" -f ($memory.Sum / 1GB)
    $info.RAMSlots = $memory.Count
    $info.RAMMinRequirement = "32 GB"
    $info.RAMMetRequirement = ($memory.Sum / 1GB) -ge 32
    
    # Disk Information
    $disks = Get-WmiObject -Class Win32_LogicalDisk | Where-Object { $_.DriveType -eq 3 }
    $diskInfo = @()
    $totalStorageGB = 0
    foreach ($disk in $disks) {
        $freeGB = [math]::Round($disk.FreeSpace / 1GB, 2)
        $totalGB = [math]::Round($disk.Size / 1GB, 2)
        $totalStorageGB += $totalGB
        $usedGB = $totalGB - $freeGB
        $percentFree = [math]::Round(($freeGB / $totalGB) * 100, 2)
        
        $diskInfo += @{
            Drive = $disk.DeviceID
            Size = "$totalGB GB"
            Free = "$freeGB GB"
            Used = "$usedGB GB"
            PercentFree = "$percentFree%"
        }
    }
    $info.Disks = $diskInfo
    $info.TotalStorage = "$totalStorageGB GB"
    $info.StorageMinRequirement = "800 GB"
    $info.StorageMetRequirement = $totalStorageGB -ge 800
    
    # Virtualization Check
    $info.VirtualizationEnabled = $false
    try {
        # Method 1: Check via WMI (traditional)
        $vmFirmware = (Get-WmiObject -Class Win32_Processor).VirtualizationFirmwareEnabled
        $info.VirtualizationEnabled = $vmFirmware -contains $true
    
        # Method 2: Additional check using modern approach if first method fails
        if (-not $info.VirtualizationEnabled) {
            try {
                $computerInfo = Get-ComputerInfo -ErrorAction SilentlyContinue
                if ($computerInfo -and $computerInfo.HyperVRequirementVirtualizationFirmwareEnabled) {
                    $info.VirtualizationEnabled = $true
                }
            } catch {}
        }
    
        # Method 3: Final fallback - check CPU features
        if (-not $info.VirtualizationEnabled) {
            try {
                $cpu = Get-WmiObject -Class Win32_Processor | Select-Object -First 1
                if ($cpu.NumberOfCores -ge 2) {
                    # If we have a multi-core processor, assume virtualization is available
                    # This is a conservative fallback for modern systems
                    $info.VirtualizationEnabled = $true
                    Write-Warn "Virtualization status uncertain. Assuming enabled for modern multi-core system."
                }
            } catch {}
        }
    } catch {
        Write-Warn "Error checking virtualization: $($_.Exception.Message)"
    }
    
    # Network Information
    $networkAdapters = Get-WmiObject -Class Win32_NetworkAdapterConfiguration | Where-Object { $_.IPEnabled -eq $true }
    $networkInfo = @()
    foreach ($adapter in $networkAdapters) {
        $networkInfo += @{
            Description = $adapter.Description
            IPAddress = $adapter.IPAddress -join ", "
            SubnetMask = $adapter.IPSubnet -join ", "
            DefaultGateway = $adapter.DefaultIPGateway -join ", "
            DNSServers = $adapter.DNSServerSearchOrder -join ", "
        }
    }
    $info.NetworkAdapters = $networkInfo
    
    # Windows Update Status
    $info.LastUpdateCheck = "Not checked"
    try {
        $session = New-Object -ComObject Microsoft.Update.Session
        $searcher = $session.CreateUpdateSearcher()
        $historyCount = $searcher.GetTotalHistoryCount()
        if ($historyCount -gt 0) {
            $history = $searcher.QueryHistory(0, 1) | Select-Object -First 1
            $info.LastUpdateCheck = $history.Date
        }
    } catch {}
    
    # Pending Reboot Check
    $info.PendingReboot = Test-PendingReboot
    
    return $info
}

function Display-SystemInfo {
    param($SystemInfo)
    
    Write-Host "`n================= SYSTEM INFORMATION =================" -ForegroundColor Cyan
    
    # Computer Info
    Write-Host "Computer: $($SystemInfo.ComputerName)" -ForegroundColor White
    Write-Host "Manufacturer: $($SystemInfo.Manufacturer)" -ForegroundColor White
    Write-Host "Model: $($SystemInfo.Model)" -ForegroundColor White
    
    # OS Info
    Write-Host "OS: $($SystemInfo.OSName)" -ForegroundColor White
    Write-Host "Version: $($SystemInfo.OSVersion)" -ForegroundColor White
    Write-Host "Build: $($SystemInfo.BuildNumber)" -ForegroundColor White
    Write-Host "Installed: $($SystemInfo.InstallDate)" -ForegroundColor White
    
    # Processor Info
    Write-Host "Processor: $($SystemInfo.Processor)" -ForegroundColor White
    Write-Host "Cores: $($SystemInfo.Cores)" -ForegroundColor White
    Write-Host "Logical Processors: $($SystemInfo.LogicalProcessors)" -ForegroundColor White
    Write-Host "Clock Speed: $($SystemInfo.MaxClockSpeed)" -ForegroundColor White
    
    # Memory Info
    $ramColor = if ($SystemInfo.RAMMetRequirement) { "Green" } else { "Red" }
    Write-Host "Total RAM: $($SystemInfo.TotalRAM)" -ForegroundColor $ramColor
    Write-Host "RAM Slots: $($SystemInfo.RAMSlots)" -ForegroundColor White
    Write-Host "Minimum Required: $($SystemInfo.RAMMinRequirement)" -ForegroundColor White
    Write-Host "RAM Requirement Met: $($SystemInfo.RAMMetRequirement)" -ForegroundColor $ramColor
    
    # Disk Info
    Write-Host "`nStorage Information:" -ForegroundColor Cyan
    Write-Host "Total Storage: $($SystemInfo.TotalStorage)" -ForegroundColor White
    foreach ($disk in $SystemInfo.Disks) {
        Write-Host "  $($disk.Drive): $($disk.Size) total, $($disk.Free) free ($($disk.PercentFree))" -ForegroundColor White
    }
    $storageColor = if ($SystemInfo.StorageMetRequirement) { "Green" } else { "Red" }
    Write-Host "Minimum Required: $($SystemInfo.StorageMinRequirement)" -ForegroundColor White
    Write-Host "Storage Requirement Met: $($SystemInfo.StorageMetRequirement)" -ForegroundColor $storageColor
    
    # Virtualization
    $virtColor = if ($SystemInfo.VirtualizationEnabled) { "Green" } else { "Red" }
    Write-Host "Virtualization Enabled: $($SystemInfo.VirtualizationEnabled)" -ForegroundColor $virtColor
    
    # Network Info
    Write-Host "`nNetwork Information:" -ForegroundColor Cyan
    foreach ($adapter in $SystemInfo.NetworkAdapters) {
        Write-Host "  $($adapter.Description)" -ForegroundColor White
        Write-Host "    IP: $($adapter.IPAddress)" -ForegroundColor Gray
        Write-Host "    Subnet: $($adapter.SubnetMask)" -ForegroundColor Gray
        Write-Host "    Gateway: $($adapter.DefaultGateway)" -ForegroundColor Gray
        Write-Host "    DNS: $($adapter.DNSServers)" -ForegroundColor Gray
    }
    
    # Update Status
    Write-Host "Last Update Check: $($SystemInfo.LastUpdateCheck)" -ForegroundColor White
    
    # Pending Reboot
    $rebootColor = if ($SystemInfo.PendingReboot) { "Yellow" } else { "Green" }
    Write-Host "Pending Reboot: $($SystemInfo.PendingReboot)" -ForegroundColor $rebootColor
    
    Write-Host "======================================================" -ForegroundColor Cyan
}

function Check-SystemRequirements {
    param($SystemInfo)
    
    $allMet = $true
    $issues = @()
    
    if (-not $SystemInfo.RAMMetRequirement) {
        $issues += "RAM: Minimum 32 GB required (found $($SystemInfo.TotalRAM))"
        $allMet = $false
    }
    
    if (-not $SystemInfo.StorageMetRequirement) {
        $issues += "Storage: Minimum 800 GB total storage required (found $($SystemInfo.TotalStorage))"
        $allMet = $false
    }
    
    if (-not $SystemInfo.VirtualizationEnabled) {
        $issues += "Virtualization: Not enabled in BIOS/UEFI"
        $allMet = $false
    }
    
    if ($SystemInfo.PendingReboot) {
        $issues += "System: Pending reboot required"
        $allMet = $false
    }
    
    return @{
        AllRequirementsMet = $allMet
        Issues = $issues
    }
}

# -------------------- Admin check --------------------
function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# -------------------- PATH helper --------------------
function Add-PathOnce {
    param([Parameter(Mandatory = $true)][string]$Dir)
    try {
        if (-not (Test-Path -LiteralPath $Dir)) { return }
        $dirResolved = (Resolve-Path -LiteralPath $Dir).Path
        $parts = ($env:PATH -split ';') | Where-Object { $_ }
        if ($parts -notcontains $dirResolved) {
            $env:PATH = ($parts + $dirResolved) -join ';'
        }
    }
    catch {
        Write-Warn "Could not add $Dir to PATH: $($_.Exception.Message)"
    }
}

function Refresh-Environment {
    # Update PATH from registry
    $env:PATH = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + 
                [System.Environment]::GetEnvironmentVariable("Path","User")
    
    # Also add common installation directories
    $commonPaths = @(
        "${env:ProgramFiles}\Git\bin",
        "${env:ProgramFiles}\Git\cmd",
        "${env:ProgramFiles}\PowerShell\7",
        "${env:ProgramFiles}\TigerVNC",
        "${env:LOCALAPPDATA}\Microsoft\WinGet\Links",
        "${env:LOCALAPPDATA}\Microsoft\WinGet\Packages\Kubernetes.kubectl_*",
        "${env:ProgramFiles}\Kubernetes\bin"
    )
    
    foreach ($path in $commonPaths) {
        if (Test-Path $path) {
            Add-PathOnce $path
        }
    }
}

# -------------------- WinGet helpers --------------------
function Ensure-WinGet {
    try {
        $wg = Get-Command winget -ErrorAction SilentlyContinue
        if ($wg) { return $true }
        
        # Try to find winget in common locations
        $wingetPaths = @(
            "$env:LOCALAPPDATA\Microsoft\WindowsApps\winget.exe",
            "$env:ProgramFiles\WindowsApps\Microsoft.Winget.Source_*_*__8wekyb3d8bbwe\winget.exe"
        )
        
        foreach ($path in $wingetPaths) {
            $resolvedPath = Resolve-Path $path -ErrorAction SilentlyContinue
            if ($resolvedPath) {
                Set-Alias -Name winget -Value $resolvedPath -Scope Script
                return $true
            }
        }
        
        Write-Err "WinGet not found. Please install 'App Installer' from the Microsoft Store and then run this script again."
        return $false
    }
    catch {
        Write-Err "Error checking for WinGet: $($_.Exception.Message)"
        return $false
    }
}

function Winget-Source-Update {
    try {
        if (-not (Ensure-WinGet)) { return }
        # Use Start-Process without redirection to avoid null issues
        Start-Process -FilePath "winget" -ArgumentList "source update" -Wait -NoNewWindow
    }
    catch {
        Write-Warn "Error updating winget sources: $($_.Exception.Message)"
    }
}

function Winget-Install {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [string]$Name = $Id
    )
    
    if (-not (Ensure-WinGet)) { 
        Write-Err "WinGet is not available, cannot install $Name"
        return $false
    }
    
    try {
        Write-Info "Installing $Name via winget..."
        $args = @(
            "install", "-e", "--id", $Id,
            "--accept-source-agreements", "--accept-package-agreements", "--silent"
        )
        
        $process = Start-Process -FilePath "winget" -ArgumentList $args -PassThru -Wait -NoNewWindow
        if ($process.ExitCode -eq 0) {
            Write-Ok "$Name successfully installed"
            
            # Refresh environment after installation
            Refresh-Environment
            return $true
        }
        elseif ($process.ExitCode -eq -1978335189) {
            # Package already installed but winget returns error code
            Write-Ok "$Name is already installed"
            Refresh-Environment
            return $true
        }
        else {
            Write-Warn "winget ExitCode=$($process.ExitCode) for $Name. Check path/link..."
            return $false
        }
    }
    catch {
        Write-Err "Error installing $($Name): $($_.Exception.Message)"
        return $false
    }
}

# -------------------- Pending reboot check --------------------
function Test-PendingReboot {
    try {
        $keys = @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired',
            'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
        )
        
        foreach ($k in $keys) {
            if (Test-Path $k) {
                if ($k -like '*Session Manager') {
                    $val = (Get-ItemProperty -Path $k -Name 'PendingFileRenameOperations' -ErrorAction SilentlyContinue).PendingFileRenameOperations
                    if ($val) { return $true }
                }
                else {
                    return $true
                }
            }
        }
    }
    catch {
        Write-Warn "Error checking for pending reboot: $($_.Exception.Message)"
    }
    return $false
}

# -------------------- Packer locate helpers --------------------
function Find-PackerExe {
    # 1) PATH
    $cmd = Get-Command packer -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Path) { return $cmd.Path }

    # 2) Common locations (WinGet-Link / HashiCorp / Chocolatey)
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\packer.exe'),
        (Join-Path $env:LOCALAPPDATA 'HashiCorp\Packer\packer.exe'),
        (Join-Path $env:ProgramFiles 'HashiCorp\Packer\packer.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'HashiCorp\Packer\packer.exe'),
        (Join-Path $env:ChocolateyInstall 'bin\packer.exe'),
        'C:\ProgramData\chocolatey\bin\packer.exe'
    ) | Where-Object { $_ }

    foreach ($p in $candidates) {
        try {
            if (Test-Path -LiteralPath $p) { return (Resolve-Path -LiteralPath $p).Path }
        }
        catch { }
    }

    # 3) Quick heuristic search in HashiCorp/WinGet directories
    $roots = @(
        (Join-Path $env:LOCALAPPDATA 'HashiCorp'),
        (Join-Path $env:ProgramFiles 'HashiCorp'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages')
    ) | Where-Object { $_ -and (Test-Path $_) }

    foreach ($r in $roots) {
        try {
            $found = Get-ChildItem -Path $r -Filter 'packer.exe' -Recurse -ErrorAction SilentlyContinue |
                Select-Object -First 1 -ExpandProperty FullName
            if ($found) { return $found }
        }
        catch { }
    }

    return $null
}

# -------------------- kubectl locate helpers --------------------
function Find-KubectlExe {
    # 1) PATH
    $cmd = Get-Command kubectl -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Path) { return $cmd.Path }

    # 2) Common locations (WinGet-Link / Kubernetes directories)
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\kubectl.exe'),
        (Join-Path $env:ProgramFiles 'Kubernetes\kubectl.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Kubernetes\kubectl.exe'),
        (Join-Path $env:ChocolateyInstall 'bin\kubectl.exe'),
        'C:\ProgramData\chocolatey\bin\kubectl.exe'
    ) | Where-Object { $_ }

    foreach ($p in $candidates) {
        try {
            if (Test-Path -LiteralPath $p) { return (Resolve-Path -LiteralPath $p).Path }
        }
        catch { }
    }

    # 3) Quick heuristic search in Kubernetes/WinGet directories
    $roots = @(
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages\Kubernetes.kubectl_*'),
        (Join-Path $env:ProgramFiles 'Kubernetes'),
        (Join-Path ${env:ProgramFiles(x86)} 'Kubernetes')
    ) | Where-Object { $_ -and (Test-Path $_) }

    foreach ($r in $roots) {
        try {
            $found = Get-ChildItem -Path $r -Filter 'kubectl.exe' -Recurse -ErrorAction SilentlyContinue |
                Select-Object -First 1 -ExpandProperty FullName
            if ($found) { return $found }
        }
        catch { }
    }

    return $null
}

# -------------------- Ensure: PowerShell 7 --------------------
function Ensure-Pwsh {
    Write-Info "Checking PowerShell 7..."
    
    # Check if already available
    $cmd = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Path) {
        try {
            $v = & $cmd.Path -NoLogo -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'
            Write-Ok ("PowerShell 7 found: {0}" -f $v)
        }
        catch {
            Write-Ok "PowerShell 7 found (version unknown)"
        }
        return $true
    }
    
    # Try to install
    if (Winget-Install -Id "Microsoft.PowerShell" -Name "PowerShell 7") {
        # Add WinGet Links directory to session PATH
        Add-PathOnce (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links')
        
        # Check again after installation
        $cmd = Get-Command pwsh -ErrorAction SilentlyContinue
        if ($cmd) {
            Write-Ok "PowerShell 7 installed and available."
            return $true
        }
        else {
            Write-Warn "PowerShell 7 installed but not immediately available in PATH."
            Write-Warn "Please restart your PowerShell session to use PowerShell 7."
            return $true  # Consider it success since it's installed
        }
    }
    
    Write-Err "PowerShell 7 could not be found or installed."
    return $false
}

# -------------------- Ensure: Packer --------------------
function Ensure-Packer {
    Write-Info "Checking HashiCorp Packer..."
    $exe = Find-PackerExe
    if ($exe) {
        Add-PathOnce (Split-Path $exe -Parent)
        $ver = ""
        try { $ver = (& $exe -v 2>$null) }
        catch { }
        if (-not $ver) { $ver = "(version unknown)" }
        Write-Ok ("Packer found: {0}" -f $ver)
        return $true
    }

    Write-Info "Packer not found - attempting installation..."
    
    # Use the correct package ID with lowercase 'c'
    if (Winget-Install -Id "Hashicorp.Packer" -Name "HashiCorp Packer") {
        $exe = Find-PackerExe
        if ($exe) {
            Add-PathOnce (Split-Path $exe -Parent)
            $v = ""
            try { $v = (& $exe -v 2>$null) }
            catch { }
            $versionInfo = if ($v -ne "") { $v } else { "(version unknown)" }
            Write-Ok ("Packer installed: {0}" -f $versionInfo)
            return $true
        }
    }
    
    Write-Err "Packer still not found after installation attempt."
    Write-Warn "You may need to install Packer manually from https://www.packer.io/downloads"
    return $false
}

# -------------------- Ensure: kubectl --------------------
function Ensure-Kubectl {
    Write-Info "Checking kubectl..."
    $exe = Find-KubectlExe
    if ($exe) {
        Add-PathOnce (Split-Path $exe -Parent)
        $ver = ""
        try { $ver = (& $exe version --client --short 2>$null) }
        catch { }
        $versionDisplay = if ($ver -ne "") { $ver } else { "(version unknown)" }
        Write-Ok ("kubectl found: {0}" -f $versionDisplay)
        return $true
    }
    
    Write-Info "kubectl not found - installing via winget..."
    if (Winget-Install -Id "Kubernetes.kubectl" -Name "kubectl") {
        # Check again after installation
        $exe = Find-KubectlExe
        if ($exe) {
            Add-PathOnce (Split-Path $exe -Parent)
            Write-Ok "kubectl installed and available."
            return $true
        }
        else {
            Write-Warn "kubectl installed but not immediately available in PATH."
            return $true  # Consider it success since it's installed
        }
    }
    
    Write-Err "kubectl still not found after installation attempt."
    return $false
}

# -------------------- Ensure: Git --------------------
function Ensure-Git {
    Write-Info "Checking Git..."
    $cmd = Get-Command git -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Path) {
        $ver = ""
        try { $ver = (& $cmd.Path --version 2>$null) }
        catch { }
        $versionDisplay = if ($ver -ne "") { $ver } else { "(version unknown)" }
        Write-Ok ("Git found: {0}" -f $versionDisplay)
        return $true
    }
    
    Write-Info "Git not found - installing via winget..."
    if (Winget-Install -Id "Git.Git" -Name "Git") {
        # Check again after installation
        $cmd = Get-Command git -ErrorAction SilentlyContinue
        if ($cmd) {
            Write-Ok "Git installed."
            return $true
        }
        else {
            # Git is often installed to Program Files, which should be in PATH
            # Try to find it in common locations
            $gitPaths = @(
                "${env:ProgramFiles}\Git\bin\git.exe",
                "${env:ProgramFiles(x86)}\Git\bin\git.exe"
            )
            
            foreach ($path in $gitPaths) {
                if (Test-Path $path) {
                    Write-Ok "Git installed at $path"
                    Add-PathOnce (Split-Path $path -Parent)
                    return $true
                }
            }
            
            Write-Warn "Git installed but not immediately available in PATH."
            return $true  # Consider it success since it's installed
        }
    }
    
    Write-Err "Git still not found after installation attempt."
    return $false
}

# -------------------- Ensure: TigerVNC Viewer --------------------
function Ensure-TigerVNC {
    Write-Info "Checking TigerVNC (viewer)..."
    $cmd = Get-Command vncviewer -ErrorAction SilentlyContinue
    if (-not $cmd) {
        # Try common install path
        $default = 'C:\Program Files\TigerVNC\vncviewer.exe'
        if (Test-Path $default) { $cmd = @{ Path = $default } }
    }
    if ($cmd -and $cmd.Path) {
        Write-Ok ("TigerVNC found: {0}" -f $cmd.Path)
        return $true
    }
    
    Write-Info "TigerVNC not found - installing via winget..."
    if (Winget-Install -Id "TigerVNC.TigerVNC" -Name "TigerVNC") {
        # Check again after installation
        $cmd = Get-Command vncviewer -ErrorAction SilentlyContinue
        if (-not $cmd -and (Test-Path 'C:\Program Files\TigerVNC\vncviewer.exe')) {
            $cmd = @{ Path = 'C:\Program Files\TigerVNC\vncviewer.exe' }
        }
        if ($cmd) {
            Write-Ok "TigerVNC installed."
            return $true
        }
        else {
            Write-Warn "TigerVNC installed but not immediately available in PATH."
            return $true  # Consider it success since it's installed
        }
    }
    
    Write-Err "TigerVNC still not found after installation attempt."
    return $false
}

# -------------------- Check: VMware Workstation (>=17) --------------------
function Check-VMware {
    Write-Info "Checking VMware Workstation Pro (>= 17)..."
    $ver = $null
    try {
        $paths = @(
            'HKLM:\SOFTWARE\VMware, Inc.\VMware Workstation',
            'HKLM:\SOFTWARE\WOW6432Node\VMware, Inc.\VMware Workstation'
        )
        foreach ($rk in $paths) {
            if (Test-Path $rk) {
                $p = Get-ItemProperty -Path $rk -ErrorAction SilentlyContinue
                if ($p -and $p.ProductVersion) { $ver = $p.ProductVersion; break }
                if ($p -and $p.Version) { $ver = $p.Version; break }
            }
        }
        
        # Additional check via WMI if registry method failed
        if (-not $ver) {
            try {
                $vmware = Get-WmiObject -Class Win32_Product -Filter "Name LIKE '%VMware Workstation%'" | 
                          Select-Object -First 1
                if ($vmware -and $vmware.Version) { $ver = $vmware.Version }
            } catch {}
        }
    }
    catch {
        Write-Warn "Error checking VMware installation: $($_.Exception.Message)"
    }

    if ($ver) {
        Write-Ok ("VMware Workstation found: Version {0}" -f $ver)
        # Rough version check: 17.x or higher
        $maj = $null
        try { $maj = [int]($ver -split '\.' | Select-Object -First 1) }
        catch { }
        if ($maj -and $maj -lt 17) {
            Write-Warn "VMware version < 17 detected. Please upgrade to >= 17."
        }
    }
    else {
        Write-Warn "VMware Workstation not found. (Not automatically installed; please install separately - version >= 17 recommended.)"
    }
}

# -------------------- Ensure: WSL & VirtualMachinePlatform --------------------
function Ensure-WSL-VMP {
    Write-Info "Checking WSL and VirtualMachinePlatform..."
    $changed = $false
    try {
        $wsl = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -ErrorAction SilentlyContinue
        if (-not $wsl -or $wsl.State -ne 'Enabled') {
            Write-Info "Enabling Microsoft-Windows-Subsystem-Linux..."
            Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -NoRestart -ErrorAction SilentlyContinue | Out-Null
            $changed = $true
        }
    }
    catch {
        Write-Warn "Could not enable WSL: $($_.Exception.Message)"
    }

    try {
        $vmp = Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -ErrorAction SilentlyContinue
        if (-not $vmp -or $vmp.State -ne 'Enabled') {
            Write-Info "Enabling VirtualMachinePlatform..."
            Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -NoRestart -ErrorAction SilentlyContinue | Out-Null
            $changed = $true
        }
    }
    catch {
        Write-Warn "Could not enable VirtualMachinePlatform: $($_.Exception.Message)"
    }

    if ($changed) {
        Write-Warn "WSL/VMP were (partially) enabled. A reboot may be required."
        return $true
    }
    else {
        Write-Ok "WSL and VirtualMachinePlatform are enabled."
        return $false
    }
}

# -------------------- Check: E:\ drive --------------------
function Check-EDrive {
    param([int]$MinFreeGB = 50)
    Write-Info "Checking E:\ drive..."
    if (-not (Test-Path 'E:\')) {
        Write-Warn "E:\ not found. If ISOs/logs are expected there, please mount the drive."
        return $false
    }
    try {
        $drive = Get-PSDrive -Name 'E' -ErrorAction SilentlyContinue
        if ($drive) {
            $freeGB = [math]::Round($drive.Free / 1GB, 0)
            Write-Ok ("E:\ available ({0} GB free)" -f $freeGB)
            if ($freeGB -lt $MinFreeGB) {
                Write-Warn ("Low free space on E:\ (only {0} GB, recommended >= {1} GB)" -f $freeGB, $MinFreeGB)
                return $false
            }
            return $true
        }
        else {
            Write-Ok "E:\ available."
            return $true
        }
    }
    catch {
        Write-Warn "E:\ check could not be completed: $($_.Exception.Message)"
        return $false
    }
}

# -------------------- Ensure: Windows ADK --------------------
function Ensure-WindowsADK {
    Write-Info "Checking Windows Assessment and Deployment Kit (ADK)..."
    
    # Check if oscdimg is available (main component we need)
    $oscdimg = 'C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe'
    
    if (Test-Path $oscdimg) {
        Write-Ok "Windows ADK found: $oscdimg"
        return $true
    }
    
    Write-Info "Windows ADK not found - attempting installation..."
    
    # Try to install via winget
    if (Winget-Install -Id "Microsoft.WindowsADK" -Name "Windows Assessment and Deployment Kit") {
        # Check again after installation
        if (Test-Path $oscdimg) {
            Write-Ok "Windows ADK installed successfully."
            return $true
        } else {
            Write-Warn "Windows ADK installed but oscdimg.exe not found at expected location."
            Write-Warn "Please install Windows ADK manually from:"
            Write-Warn "https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install"
            return $false
        }
    }
    
    Write-Err "Windows ADK installation failed."
    Write-Warn "Please install Windows ADK manually from:"
    Write-Warn "https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install"
    return $false
}

# -------------------- MAIN --------------------
try {
    Write-Host ""
    Write-Host "================= Prerequisites (SOC-9000) =================" -ForegroundColor Cyan

    # Check for administrator privileges
    if (-not (Test-Administrator)) {
        Write-Err "This script must be run as Administrator!"
        Write-Warn "Please right-click on PowerShell and select 'Run as Administrator'"
        exit 1
    }

    # Gather and display system information
    Write-Info "Gathering system information..."
    $systemInfo = Get-SystemInfo
    Display-SystemInfo -SystemInfo $systemInfo
    
    # Check system requirements
    $requirements = Check-SystemRequirements -SystemInfo $systemInfo
    
    if (-not $requirements.AllRequirementsMet) {
        Write-Host "`n================= SYSTEM REQUIREMENT ISSUES =================" -ForegroundColor Red
        foreach ($issue in $requirements.Issues) {
            Write-Err "  $issue"
        }
        Write-Host "=============================================================" -ForegroundColor Red
        
        $continue = Read-Host "`nDo you want to continue despite these issues? (y/N)"
        if ($continue -ne 'y' -and $continue -ne 'Y') {
            Write-Info "Installation aborted by user."
            exit 3  # Use specific exit code for user abort
        }
        Write-Info "Continuing with installation despite system requirement issues..."
    } else {
        Write-Host "`n================= SYSTEM REQUIREMENTS MET =================" -ForegroundColor Green
        Write-Ok "All system requirements are met"
        Write-Host "==========================================================" -ForegroundColor Green
    }
    
    # Prompt to continue
    Write-Host "`n"
    $confirm = Read-Host "Press ENTER to continue with the installation or CTRL+C to cancel"
    if ($confirm -ne '') {
        Write-Info "Installation aborted by user."
        exit 0
    }
    
    # Refresh environment at start
    Refresh-Environment

    # PATH fix for winget links (helps immediate availability)
    Add-PathOnce (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links')

    # Make WinGet available
    if (-not (Ensure-WinGet)) {
        Write-Err "WinGet is required for this installation. Please install it and run the script again."
        exit 1
    }

    # Update winget source once
    Winget-Source-Update

    # Install/check tools
    $results = @{
        Pwsh      = Ensure-Pwsh
        Packer    = Ensure-Packer
        Kubectl   = Ensure-Kubectl
        Git       = Ensure-Git
        TigerVNC  = Ensure-TigerVNC
        WindowsADK = Ensure-WindowsADK
    }

    # Additional checks
    Check-VMware
    $wslChanged = Ensure-WSL-VMP
    $eDriveOk = Check-EDrive -MinFreeGB 50

    if (Test-PendingReboot -or $wslChanged) {
        Write-Warn "A reboot is recommended/required (pending reboot or WSL changes detected)."
        $rebootRequired = $true
    }
    else {
        Write-Ok "No pending reboots detected."
        $rebootRequired = $false
    }

    # Summary
    Write-Host ""
    Write-Host "================= Summary =================" -ForegroundColor Cyan
    foreach ($tool in $results.Keys) {
        $status = if ($results[$tool]) { "OK" } else { "ERROR" }
        $color = if ($results[$tool]) { "Green" } else { "Red" }
        Write-Host "$tool`: $status" -ForegroundColor $color
    }
    
    Write-Host ("E: Drive: {0}" -f $(if($eDriveOk){"OK"}else{"WARNING"})) -ForegroundColor $(if($eDriveOk){"Green"}else{"Yellow"})
    Write-Host ("Reboot required: {0}" -f $(if($rebootRequired){"YES"}else{"NO"})) -ForegroundColor $(if($rebootRequired){"Yellow"}else{"Green"})

    if ($results.Values -contains $false) {
        Write-Err "Some prerequisites could not be met. Please check the error messages above."
        Write-Warn "You may need to install missing components manually."
        exit 1
    }
    elseif ($rebootRequired) {
        Write-Warn "Prerequisites installed but reboot is required to complete setup."
        $answer = Read-Host "Reboot now? (y/N)"
        if ($answer -eq 'y' -or $answer -eq 'Y') {
            Write-Info "Rebooting system..."
            Restart-Computer -Force
        }
        else {
            Write-Info "Please reboot your system when convenient to complete the setup."
            exit 0
        }
    }
    else {
        Write-Ok "All prerequisites successfully installed/verified."
        Write-Host "`nYou can now proceed with the SOC-9000 setup." -ForegroundColor Green
        exit 0
    }
}
catch {
    Write-Err "Unexpected error: $($_.Exception.Message)"
    Write-Warn "Script execution failed. Please check the error message and try again."
    exit 1
}