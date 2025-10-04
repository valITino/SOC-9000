packer {
  required_plugins {
    vmware = {
      source  = "github.com/hashicorp/vmware"
      version = ">= 1.1.1"
    }
  }
}

# ==================== VARIABLES ====================

variable "iso_path" {
  type        = string
  description = "Path to pfSense ISO file"
  default     = "E:/SOC-9000-Install/isos/pfSense-CE-2.7.2-RELEASE-amd64.iso"
}

variable "iso_checksum" {
  type        = string
  description = "ISO checksum (sha256:xxx or 'none' to skip)"
  default     = "none"
}

variable "output_dir" {
  type        = string
  description = "Output directory for VM"
  default     = "E:/SOC-9000-Install/VMs"
}

variable "vm_name" {
  type        = string
  description = "VM name"
  default     = "pfsense"
}

variable "disk_size_mb" {
  type        = number
  description = "Disk size in MB"
  default     = 20000  # 20 GB
}

variable "cpus" {
  type        = number
  description = "Number of CPUs"
  default     = 2
}

variable "memory_mb" {
  type        = number
  description = "RAM in MB"
  default     = 2048  # 2 GB
}

variable "ssh_username" {
  type        = string
  description = "SSH username for pfSense"
  default     = "admin"
}

variable "ssh_password" {
  type        = string
  description = "Admin password for pfSense"
  default     = "pfsense"
  sensitive   = true
}

# ==================== SOURCE ====================

source "vmware-iso" "pfsense" {
  vm_name       = var.vm_name
  guest_os_type = "freebsd-64"

  iso_url      = var.iso_path
  iso_checksum = var.iso_checksum

  firmware  = "bios"
  headless  = true

  # pfSense doesn't support SSH during install, use VNC for monitoring
  vnc_bind_address = "127.0.0.1"

  cpus   = var.cpus
  memory = var.memory_mb

  disk_size             = var.disk_size_mb
  disk_type_id          = "0"  # SCSI
  disk_adapter_type     = "lsilogic"

  network_adapter_type  = "e1000"

  # 5 NICs for pfSense (WAN + 4 internal networks)
  # NIC 1: WAN (VMnet8 NAT) - assigned during wiring
  # NIC 2: MGMT (VMnet20) - assigned during wiring
  # NIC 3: SOC (VMnet21) - assigned during wiring
  # NIC 4: VICTIM (VMnet22) - assigned during wiring
  # NIC 5: RED (VMnet23) - assigned during wiring
  network = "nat"  # Initial NIC on NAT, will be rewired later

  vmx_data = {
    "ethernet1.present"          = "TRUE"
    "ethernet1.networkName"      = "nat"
    "ethernet1.virtualDev"       = "e1000"
    "ethernet1.addressType"      = "generated"

    "ethernet2.present"          = "TRUE"
    "ethernet2.networkName"      = "nat"
    "ethernet2.virtualDev"       = "e1000"
    "ethernet2.addressType"      = "generated"

    "ethernet3.present"          = "TRUE"
    "ethernet3.networkName"      = "nat"
    "ethernet3.virtualDev"       = "e1000"
    "ethernet3.addressType"      = "generated"

    "ethernet4.present"          = "TRUE"
    "ethernet4.networkName"      = "nat"
    "ethernet4.virtualDev"       = "e1000"
    "ethernet4.addressType"      = "generated"
  }

  # pfSense automated installation via serial console
  # Boot commands sent during installer
  boot_wait    = "10s"
  boot_command = [
    # Accept EULA
    "<enter><wait5>",

    # Install pfSense (option 1)
    "<enter><wait5>",

    # Continue with default keymap
    "<enter><wait5>",

    # Auto (UFS) partition
    "<enter><wait60>",

    # Manual configuration - NO (we'll configure via Ansible)
    "n<wait5>",

    # Reboot
    "<enter><wait30>",

    # After reboot, configure interfaces from console
    # Assign interfaces: no VLANs
    "n<enter><wait5>",

    # WAN interface: em0
    "em0<enter><wait2>",

    # LAN interface: em1
    "em1<enter><wait2>",

    # Additional LAN interfaces
    "em2<enter><wait2>",
    "em3<enter><wait2>",
    "em4<enter><wait2>",

    # No more interfaces
    "<enter><wait5>",

    # Confirm
    "y<enter><wait10>",

    # Set LAN IP address (option 2)
    "2<enter><wait2>",

    # Select interface 2 (LAN - em1)
    "2<enter><wait2>",

    # Configure IPv4 via DHCP? No
    "n<enter><wait2>",

    # LAN IPv4 address: 172.22.10.1
    "172.22.10.1<enter><wait2>",

    # Subnet mask: 24
    "24<enter><wait5>",

    # No upstream gateway
    "<enter><wait2>",

    # IPv6 via DHCP6? No
    "n<enter><wait2>",

    # No IPv6
    "<enter><wait5>",

    # Enable DHCP on LAN? No
    "n<enter><wait5>",

    # Revert to HTTP for webConfigurator? No
    "n<enter><wait10>",

    # Enable SSH (option 14)
    "14<enter><wait2>",

    # Enable Secure Shell? Yes
    "y<enter><wait10>"
  ]

  # SSH communicator for post-install
  communicator         = "ssh"
  ssh_username         = var.ssh_username
  ssh_password         = var.ssh_password
  ssh_timeout          = "30m"
  ssh_handshake_attempts = 100

  # Wait for SSH on LAN IP
  ssh_host = "172.22.10.1"

  output_directory = "${var.output_dir}/${var.vm_name}"

  shutdown_command = "/sbin/poweroff"
  shutdown_timeout = "5m"
}

# ==================== BUILD ====================

build {
  sources = ["source.vmware-iso.pfsense"]

  # Minimal provisioning - actual config will be done via Ansible
  provisioner "shell" {
    inline = [
      "echo 'pfSense VM build complete'",
      "echo 'Version: ' && cat /etc/version",
      "echo 'Interfaces: ' && ifconfig -a | grep '^[a-z]'"
    ]
  }

  post-processor "manifest" {
    output     = "${var.output_dir}/${var.vm_name}/packer-manifest.json"
    strip_path = true
  }
}
