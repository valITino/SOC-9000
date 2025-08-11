# SOC-9000 Overview

## Topology

Internet
|
VMnet8 (NAT)
|
[ pfSense ]--VMnet20 MGMT (172.22.10.0/24)
| --VMnet21 SOC (172.22.20.0/24)
| -VMnet22 VICTIM (172.22.30.0/24)
| \VMnet23 RED (172.22.40.0/24)
|
[ ContainerHost (k3s, Portainer, Traefik, MetalLB, all SOC apps) ]
[ Windows 11 victim (VICTIM segment) ]

Service URLs (via Traefik + local CA; assigned by MetalLB):
- `https://wazuh.lab.local`
- `https://thehive.lab.local`
- `https://cortex.lab.local`
- `https://caldera.lab.local`
- `https://nessus.lab.local`
- `https://portainer.lab.local`
