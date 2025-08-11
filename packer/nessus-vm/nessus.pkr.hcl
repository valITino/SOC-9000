packer {
  required_plugins {
    vmware = {
      source  = "github.com/hashicorp/vmware"
      version = ">= 1.1.1"
    }
  }
}

variable "iso_path"      { type = string, default = "E:/SOC-9000/isos/ubuntu-22.04.iso" }
variable "vm_name"       { type = string, default = "nessus-vm" }
variable "cpus"          { type = number, default = 2 }
variable "memory_mb"     { type = number, default = 4096 }
variable "disk_size_mb"  { type = number, default = 60000 }
variable "ssh_username"  { type = string, default = "labadmin" }
variable "ssh_password"  { type = string, default = "ChangeMe_S0C9000!" }
variable "vmnet"         { type = string, default = "VMnet21" }            # SOC
variable "ip_addr"       { type = string, default = "172.22.20.60" }
variable "ip_gw"         { type = string, default = "172.22.20.1" }
variable "ip_dns"        { type = string, default = "172.22.20.1" }

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
  network              = var.vmnet

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

  # Render netplan with static IP
  provisioner "file" {
    destination = "/home/${var.ssh_username}/50-soc-nessus.yaml"
    content     = templatefile("${path.root}/http/netplan.tmpl", {
      ip_addr = var.ip_addr, ip_gw = var.ip_gw, ip_dns = var.ip_dns
    })
  }
  provisioner "shell" {
    inline = [
      "echo '${var.ssh_password}' | sudo -S mv /home/${var.ssh_username}/50-soc-nessus.yaml /etc/netplan/50-soc-nessus.yaml",
      "echo '${var.ssh_password}' | sudo -S netplan apply"
    ]
  }
}
