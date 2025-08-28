packer {
  required_plugins {
    vmware = {
      source  = "github.com/hashicorp/vmware"
      version = ">= 1.1.1"
    }
  }
}

variable "iso_path" {
  type    = string
  default = "E:/SOC-9000-Install/isos/Win11_24H2_noprompt_autounattend_uefi.iso"
}

variable "output_dir" {
  type    = string
  default = "E:/SOC-9000-Install/VMs/Windows"
}

variable "vm_name" {
  type    = string
  default = "victim-win"
}

variable "admin_password" {
  type    = string
  default = "ChangeMe_S0C9000!"
}

variable "disk_size_mb" {
  type    = number
  default = 80000
}

variable "cpus" {
  type    = number
  default = 4
}

variable "memory_mb" {
  type    = number
  default = 8192
}

source "vmware-iso" "win11" {
  vm_name                     = var.vm_name
  iso_url                     = var.iso_path
  iso_checksum                = "sha256:84777A4095C58112B1EA7F19AAB7F533AD89081B051ED129F8265BA9FD4B5140"

  guest_os_type        = "windows11-64"     # maps to guestOS = "windows11-64"
  firmware             = "efi-secure"              
  version              = 21                 # virtualHW.version
  cdrom_adapter_type   = "sata"              
  network_adapter_type = "vmxnet3"          # or vmxnet3; see note below


  vmx_data = {
      "sata0.present"          = "true"
      "sata0:0.startConnected"  = "true"
    # "ethernet0.virtualDev"    = "e1000e"      # If you insist on e1000e like your manual VM:
      "managedVM.autoAddVTPM"   = "software"
  }

  headless               = true
  cpus                   = var.cpus
  memory                 = var.memory_mb
  disk_size              = var.disk_size_mb
  disk_adapter_type      = "nvme"  # Use NVMe for disk instead of SCSI

  output_directory       = "${var.output_dir}/${var.vm_name}"

  communicator           = "winrm"
  winrm_username         = "labadmin"
  winrm_password         = var.admin_password
  winrm_timeout          = "30m"
  winrm_insecure         = true
  winrm_use_ssl          = false


  # Graceful guest shutdown after provisioning
  shutdown_command = "C:\\Windows\\System32\\shutdown.exe /s /t 0 /f /d p:2:4"
}

build {
  sources = ["source.vmware-iso.win11"]

  provisioner "powershell" {
  inline = ["whoami", "Get-Service WinRM | fl"]
  }
}