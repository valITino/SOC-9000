packer {
  required_plugins {
    vmware = {
      source  = "github.com/hashicorp/vmware"
      version = ">= 1.1.1"
    }
  }
}

# ---------- Variables ----------
variable "iso_path" {
  type    = string
  default = "E:/SOC-9000-Install/isos/ubuntu-22.04.iso"
}
variable "ssh_username" {
  type    = string
  default = "labadmin"
}
variable "ssh_private_key_file" {
  type    = string
  default = "E:/SOC-9000-Install/keys/id_ed25519"
}
variable "output_dir" {
  type    = string
  default = "E:/SOC-9000-Install/VMs"
}
variable "vm_name" {
  type    = string
  default = "container-host"
}
variable "disk_size_mb" {
type = number
default = 100000
}
variable "cpus"{
type = number
default = 6
}
variable "memory_mb"{
type = number
default = 16384
}

# Bind the HTTP seed server to the host IP on VMnet8 (passed by the build script)
variable "vmnet8_host_ip" { type = string }

# Optional ISO checksum for integrity validation
# Ubuntu 22.04.5 LTS: sha256:9bc6028870aef3f74f4e16b900008179e78b130e6b0b9a140635434a46aa98b0
# Ubuntu 22.04.4 LTS: sha256:c396e956a9f52c418397867d1ea5c0cf1a99a49dcf648b086d2fb762330cc88d
# Set to "none" to skip validation (not recommended for production)
variable "iso_checksum" {
  type    = string
  default = "none"
  # Recommended: default = "sha256:9bc6028870aef3f74f4e16b900008179e78b130e6b0b9a140635434a46aa98b0"
}

# ---------- Builder ----------
source "vmware-iso" "ubuntu2204" {
  vm_name                  = var.vm_name
  iso_url                  = var.iso_path
  iso_checksum             = var.iso_checksum

  firmware                 = "bios"
  headless                 = true
  vnc_bind_address         = "127.0.0.1"

  # Serve NoCloud seed over HTTP from the repo's http/ folder
  http_directory           = "${path.root}/http"
  http_bind_address        = var.vmnet8_host_ip
  http_port_min            = 8800
  http_port_max            = 8800

  communicator             = "ssh"
  ssh_username             = var.ssh_username
  ssh_private_key_file     = var.ssh_private_key_file
  ssh_timeout              = "60m"
  ssh_handshake_attempts   = 500

  cpus                     = var.cpus
  memory                   = var.memory_mb
  disk_size                = var.disk_size_mb
  network_adapter_type     = "e1000e"
  network                  = "nat"

  # Put the VM under INSTALL_ROOT\VMs\<vm_name>
  output_directory         = "${var.output_dir}/${var.vm_name}"

  vmx_data = {
    "bios.bootDelay" = "3000"
  }

  # Robust GRUB edit (no quotes; slower typing)
  boot_wait         = "20s"
  boot_key_interval = "70ms"
  boot_command = [
    "<esc><esc><wait>",
    "e<wait>",

    # Then go down 3 lines and back up 1 → reliably lands on the 'linux' line
    "<down><down><down><end>",

    # Append to the *same* linux line (no newline!)
    " autoinstall net.ifnames=0 biosdevname=0 ip=dhcp ds='nocloud-net;s=http://${var.vmnet8_host_ip}:8800/'",

    "<f10>"
  ]

  shutdown_command = "sudo shutdown -P now"
}

# ---------- Build ----------
build {
  sources = ["source.vmware-iso.ubuntu2204"]

  provisioner "shell" {
    script          = "${path.root}/scripts/postinstall.sh"
    execute_command = "chmod +x {{ .Path }}; sudo /bin/bash '{{ .Path }}'"
  }
}