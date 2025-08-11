packer {
  required_plugins {
    vmware = {
      source  = "github.com/hashicorp/vmware"
      version = ">= 1.1.1"
    }
  }
}

variable "iso_path"       { type = string, default = "E:/SOC-9000/isos/win11-eval.iso" }
variable "vm_name"        { type = string, default = "victim-win" }
variable "admin_password" { type = string, default = "ChangeMe_S0C9000!" }
variable "disk_size_mb"   { type = number, default = 80000 }
variable "cpus"           { type = number, default = 4 }
variable "memory_mb"      { type = number, default = 8192 }

source "vmware-iso" "win11" {
  vm_name              = var.vm_name
  iso_url              = var.iso_path
  iso_checksum         = "none"

  headless             = true
  cpus                 = var.cpus
  memory               = var.memory_mb
  disk_size            = var.disk_size_mb
  network_adapter_type = "vmxnet3"

  communicator         = "winrm"
  winrm_username       = "Administrator"
  winrm_password       = var.admin_password
  winrm_timeout        = "6h"
  winrm_insecure       = true
  winrm_use_ssl        = false

  floppy_files = [
    "${path.root}/answer/Autounattend.xml",
    "${path.root}/scripts/setup-winrm.ps1",
    "${path.root}/scripts/disable-sleep.ps1"
  ]

  shutdown_command     = "shutdown /s /t 10 /f"
}

build {
  sources = ["source.vmware-iso.win11"]

  provisioner "powershell" {
    inline = ["Write-Host 'Windows base image ready for SOC-9000'"]
  }
}
