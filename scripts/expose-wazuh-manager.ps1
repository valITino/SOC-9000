# Expose wazuh-manager via MetalLB (1514/1515 TCP). Auto-detects selector labels.
param([string]$Ns="soc",[string]$LbIp="172.22.10.62")
$ErrorActionPreference="Stop"; Set-StrictMode -Version Latest
function K { param([Parameter(ValueFromRemainingArguments)]$a) kubectl @a }

if (Test-Path ".env") {
  (Get-Content .env | ? {$_ -and $_ -notmatch '^\s*#'}) | % {
    if ($_ -match '^\s*([^=]+)=(.*)$'){ $env:$($matches[1].Trim())=$matches[2].Trim() }
  }
  if ($env:WAZUH_MANAGER_LB_IP) { $LbIp = $env:WAZUH_MANAGER_LB_IP }
}

# Find a wazuh-manager pod and reuse its labels as selector
$pod = K -n $Ns get pods -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.metadata.labels}{"\n"}{end}' `
  | Select-String -Pattern "wazuh.*manager" | Select-Object -First 1
if (!$pod) { throw "Could not find wazuh manager pod labels. Is Wazuh deployed in $Ns?" }

$labelJson = $pod.ToString().Split("|")[1] | ConvertFrom-Json
$selectorPairs = $labelJson.PSObject.Properties | Where-Object { $_.Name -match 'app|app\.kubernetes\.io|component' } |
  ForEach-Object { '"'+$_.Name+'": "'+$_.Value+'"' } -join ", "

$svc = @"
apiVersion: v1
kind: Service
metadata:
  name: wazuh-manager-lb
  namespace: $Ns
  annotations:
    metallb.universe.tf/loadBalancerIPs: "$LbIp"
spec:
  type: LoadBalancer
  selector: { $selectorPairs }
  ports:
    - name: agent-data
      protocol: TCP
      port: 1514
      targetPort: 1514
    - name: agent-auth
      protocol: TCP
      port: 1515
      targetPort: 1515
  loadBalancerIP: $LbIp
"@
$svc | K apply -f -
Write-Host "Exposed wazuh-manager on $LbIp (1514/1515)."

