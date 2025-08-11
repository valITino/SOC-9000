# 1) Expose Wazuh Manager for agents
pwsh -File .\scripts\expose-wazuh-manager.ps1

# 2) Run Ansible play to wire syslog, agents, atomic, caldera
$inv = "/mnt/e/SOC-9000/SOC-9000/ansible/inventory.ini"
$play= "/mnt/e/SOC-9000/SOC-9000/ansible/site-telemetry.yml"
wsl bash -lc "ansible-playbook -i '$inv' '$play'"

Write-Host "`nTelemetry bootstrap kicked off."
Write-Host "Check Wazuh manager agents: https://wazuh.lab.local (Agents tab)."

