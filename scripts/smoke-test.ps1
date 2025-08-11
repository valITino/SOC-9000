# Basic reachability check for lab URLs (ignores TLS errors)
$ErrorActionPreference="Stop"; Set-StrictMode -Version Latest
[Net.ServicePointManager]::ServerCertificateValidationCallback = {$true}

$targets = @(
  "https://portainer.lab.local:9443",
  "https://wazuh.lab.local",
  "https://thehive.lab.local",
  "https://cortex.lab.local",
  "https://caldera.lab.local",
  "https://dvwa.lab.local",
  "https://nessus.lab.local:8834"
)

$results = foreach($t in $targets){
  try {
    $r = Invoke-WebRequest -Uri $t -Method Head -TimeoutSec 8 -UseBasicParsing
    [pscustomobject]@{ URL=$t; Status=$r.StatusCode; OK=$true }
  } catch {
    [pscustomobject]@{ URL=$t; Status=($_.Exception.Response.StatusCode.value__ 2>$null); OK=$false }
  }
}
$results | Format-Table -AutoSize

