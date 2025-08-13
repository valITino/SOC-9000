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
  default = "E:/SOC-9000/isos/ubuntu-22.04.iso"
}

variable "ssh_username" {
  type    = string
  default = "labadmin"
}

variable "ssh_password" {
  type    = string
  default = "ChangeMe_S0C9000!"
}

variable "vm_name" {
  type    = string
  default = "container-host"
}

variable "disk_size_mb" {
  type    = number
  default = 100000
}

variable "cpus" {
  type    = number
  default = 6
}

variable "memory_mb" {
  type    = number
  default = 16384
}

source "vmware-iso" "ubuntu2204" {
  vm_name              = var.vm_name
  iso_url              = var.iso_path
  iso_checksum         = "none"

  headless             = true
  http_directory       = "${path.root}/http"

  communicator         = "ssh"
  ssh_username         = var.ssh_username
  ssh_password         = var.ssh_password
  ssh_timeout          = "40m"

  cpus                 = var.cpus
  memory               = var.memory_mb
  disk_size            = var.disk_size_mb
  network_adapter_type = "vmxnet3"

  boot_wait            = "5s"
  boot_command = [
    "<esc><esc><enter><wait>",
    "/casper/vmlinuz ",
    "autoinstall ds=nocloud-net\\;s=http://{{ .HTTPIP }}:{{ .HTTPPort }}/ ",
    "initrd=/casper/initrd ",
    "-- <enter>"
  ]

  shutdown_command = "echo '${var.ssh_password}' | sudo -S shutdown -P now"
}

build {
  sources = ["source.vmware-iso.ubuntu2204"]

  provisioner "shell" {
    script = "${path.root}/scripts/postinstall.sh"
  }
}
