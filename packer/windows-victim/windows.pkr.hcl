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
  iso_checksum                = "sha256:55D5267BF5C6F329A17784C7B0B046A203EA7AD6A8E24C6B422881C33948FB4E"

  guest_os_type        = "windows11-64"     # maps to guestOS = "windows11-64"
  firmware             = "efi-secure"              
  version              = 21                 # virtualHW.version
  cdrom_adapter_type   = "sata"              
  network_adapter_type = "vmxnet3"          # or vmxnet3; see note below
  # tools_upload_flavor  = "windows"

  vmx_data = {
      "bios.bootorder"         = "cdrom,hdd"
      "sata0.present"          = "true"
      "sata0:0.startConnected"  = "true"
    # "ethernet0.virtualDev"    = "e1000e"      # If you insist on e1000e like your manual VM:
      "managedVM.autoAddVTPM"   = "software"
    # "uefi.secureboot.enabled" = "false"
    # "floppy0.present"         = "false"
    # "sata1.present"             = "true"
    # "sata1:0.present"           = "true"
    # "sata1:0.startConnected"    = "true"
  }

  headless               = false
  cpus                   = var.cpus
  memory                 = var.memory_mb
  disk_size              = var.disk_size_mb
  disk_adapter_type      = "nvme"  # Use NVMe for disk instead of SCSI

  output_directory       = "${var.output_dir}/${var.vm_name}"

  communicator           = "winrm"
  winrm_username         = "labadmin"
  winrm_password         = var.admin_password
  winrm_timeout          = "1h"
  winrm_insecure         = true
  winrm_use_ssl          = false
  
  # cd_label   = "AUTOUNATTEND"
  # cd_content = {
  # "autounattend.xml" = file("C:/Users/liamo/WebstormProjects/SOC-9000/packer/windows-victim/answer/autounattend.xml")
  # }

  # floppy_files = [
    # "${path.root}/answer/Autounattend.xml",
    # "${path.root}/scripts/setup-winrm.ps1",
    # "${path.root}/scripts/disable-sleep.ps1",
    # "${path.root}/scripts/install-vmware-tools.ps1"
  # ]

  shutdown_command       = "shutdown /s /t 5 /f /d"
}

build {
  sources = ["source.vmware-iso.win11"]

  # Install VMware Tools (optional but recommended)
  # provisioner "powershell" {
    # script = "${path.root}/scripts/install-vmware-tools.ps1"
  # }

  # provisioner "powershell" {
    # inline = ["Write-Host 'Windows base image ready for SOC-9000'"]
  # }
}