Write-Host "Disabling sleep/hibernation..."
powercfg -h off
powercfg /x -standby-timeout-ac 0
powercfg /x -hibernate-timeout-ac 0
powercfg /x -disk-timeout-ac 0
