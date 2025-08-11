# pfSense (SOC-9000)

We’ll create the pfSense VM in **Chunk 3** with a short guided install, then automatically:
- Enable SSH
- Import a ready `config.xml` (interfaces: VMnet8/20/21/22/23)
- Configure DHCP/DNS/NAT/rules per segment
- Enable syslog/NetFlow exports toward Wazuh inputs

pfSense lacks a robust unattended path on Workstation; automating post-install is far more reliable.
