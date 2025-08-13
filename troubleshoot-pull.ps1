#Requires -RunAsAdministrator

$LogFile = "C:\temp\docker_debug.log"
$LogDir = Split-Path $LogFile
if (!(Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir | Out-Null }

Start-Transcript -Path $LogFile -Append -Force

function Wait-DockerUp {
  for ($i=0; $i -lt 70; $i++) {
    try { docker info | Out-Null; if ($LASTEXITCODE -eq 0) { return } } catch {}
    Start-Sleep -Seconds 1
  }
  throw "Docker daemon didn't come up in time."
}

function Wait-DockerDown {
  for ($i=0; $i -lt 70; $i++) {
    try {
      $svc = Get-Service docker -ErrorAction Stop
      if ($svc.Status -eq 'Stopped') { return }
    } catch {}
    Start-Sleep -Seconds 1
  }
  throw "Docker service didn't stop in time."
}

# Enable debug
sc.exe qc docker | Out-Host
sc.exe stop docker
Wait-DockerDown
sc.exe config docker binPath= "\"C:\Program Files\Docker\dockerd.exe\" --run-service --debug"
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
  Wait-DockerDown
  sc.exe config docker binPath= "\"C:\Program Files\Docker\dockerd.exe\" --run-service"
  sc.exe start docker
  Wait-DockerUp
} finally {
  docker info | Select-String 'Debug Mode' | Write-Host
  sc.exe qc docker | Out-Host
}

Stop-Transcript
