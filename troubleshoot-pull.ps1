#Requires -RunAsAdministrator

$LogFile = "C:\temp\docker_debug.log"
$LogDir = Split-Path $LogFile
if (!(Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir | Out-Null }

Start-Transcript -Path $LogFile -Append -Force

function Wait-DockerUp {
  for ($i=0; $i -lt 30; $i++) {
    try { docker info | Out-Null; if ($LASTEXITCODE -eq 0) { return } } catch {}
    Start-Sleep -Seconds 1
  }
  throw "Docker daemon didn't come up in time."
}

# Enable debug
sc.exe qc docker | Out-Host
sc.exe stop docker
sc.exe config docker binPath= "C:\Windows\system32\dockerd.exe --run-service --service-name docker --debug"
sc.exe start docker
Wait-DockerUp
docker info | Select-String 'Debug Mode' | Write-Host

# Repro: clean + pull (ignore if image isn't present)
docker image rm quay.io/codefresh/cf-git-cloner:windows-21H2 2>$null
docker pull quay.io/codefresh/cf-git-cloner:windows-21H2

# Show full, untruncated daemon events for last 30 minutes
Get-WinEvent -FilterHashtable @{LogName='Application'; ProviderName='docker'; StartTime=(Get-Date).AddMinutes(-30)} |
  Sort-Object TimeCreated |
  Select-Object TimeCreated, Id, LevelDisplayName, @{n='Message'; e={$_.Message}} |
  Format-List | Out-String -Width 8192 | Write-Output

# Always revert service to non-debug
try {
  sc.exe stop docker
  sc.exe config docker binPath= "C:\Windows\system32\dockerd.exe --run-service --service-name docker"
  sc.exe start docker
  Wait-DockerUp
} finally {
  docker info | Select-String 'Debug Mode' | Write-Host
  sc.exe qc docker | Out-Host
}

Stop-Transcript
