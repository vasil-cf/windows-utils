#Requires -RunAsAdministrator
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Wait-DockerUp {
  for ($i = 0; $i -lt 30; $i++) {
    try { docker info | Out-Null; if ($LASTEXITCODE -eq 0) { return } } catch {}
    Start-Sleep -Seconds 1
  }
  throw "Docker daemon didn't come up in time."
}

# Enable per-line tracing (PowerShell 5.1). If you're on PS7+, this isn't supported.
$SupportsSetPSDebug = $PSVersionTable.PSVersion.Major -lt 7
if ($SupportsSetPSDebug) { Set-PSDebug -Trace 1 }

try {
  # --- Enable daemon debug mode ---
  sc.exe stop docker | Out-Null
  sc.exe config docker binPath= "C:\Windows\system32\dockerd.exe --run-service --service-name docker --debug" | Out-Null
  sc.exe start docker | Out-Null
  Wait-DockerUp

  docker info | Select-String 'Debug Mode' | Write-Host

  # --- Reproduce: remove image (ignore if absent) + pull ---
  docker image rm quay.io/codefresh/cf-git-cloner:windows-21H2 2>$null
  docker pull quay.io/codefresh/cf-git-cloner:windows-21H2

  # --- Dump full, untruncated daemon events for last 30 minutes ---
  Get-WinEvent -FilterHashtable @{ LogName='Application'; ProviderName='docker'; StartTime=(Get-Date).AddMinutes(-30) } |
    Sort-Object TimeCreated |
    Select-Object TimeCreated, Id, LevelDisplayName, @{ n='Message'; e={ $_.Message } } |
    Format-List | Out-String -Width 8192 | Write-Output
}
finally {
  # --- Always revert the service back to non-debug ---
  try {
    sc.exe stop docker | Out-Null
    sc.exe config docker binPath= "C:\Windows\system32\dockerd.exe --run-service --service-name docker" | Out-Null
    sc.exe start docker | Out-Null
    Wait-DockerUp

    docker info | Select-String 'Debug Mode' | Write-Host
  } catch {
    Write-Warning "Failed to revert docker service: $($_.Exception.Message)"
  }

  if ($SupportsSetPSDebug) { Set-PSDebug -Trace 0 }
}
