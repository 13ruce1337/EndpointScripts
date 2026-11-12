# Stop Windows Update related services
Write-Host "Stopping Windows Update services..."
Stop-Service -Name wuauserv -Force
Stop-Service -Name bits -Force
Stop-Service -Name cryptSvc -Force
Stop-Service -Name msiserver -Force

# Remove SoftwareDistribution and Catroot2 folders
Write-Host "Removing update cache folders..."
Remove-Item -Path "C:\Windows\SoftwareDistribution" -Recurse -Force
Remove-Item -Path "C:\Windows\System32\catroot2" -Recurse -Force

# Restart Windows Update services
Write-Host "Restarting Windows Update services..."
Start-Service -Name wuauserv
Start-Service -Name bits
Start-Service -Name cryptSvc
Start-Service -Name msiserver

Write-Host "Windows Update reset completed successfully."
