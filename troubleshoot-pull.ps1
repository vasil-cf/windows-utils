#Requires -RunAsAdministrator
<#
  Universal (PS 5.1 and PS 7+) troubleshoot script that logs EVERYTHING to a file.
  - Captures console output via Start-Transcript
  - Echoes executed commands (PS 5.1: Set-PSDebug; PS 7+: Trace-Command)
  - Temporarily enables dockerd --debug, pulls an image, dumps daemon events
  - Restores original docker service binPath on exit
#>

param(
  [string]$Image = 'quay.io/codefresh/cf-git-cloner:windows-21H2',
  [int]   $EventLookbackMinutes = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Logging setup ---
$Timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$LogDir    = Join-Path $env:ProgramData 'cf-utils-logs'
$LogPath   = Join-Path $LogDir "troubleshoot-pull_$Timestamp.log"
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
Start-Transcript -Path $LogPath -IncludeInvocationHeader -Force | Out-Null
Write-Host "Log file: $LogPath"

function Stop-Transcript-Safe { try { Stop-Transcript | Out-Null } catch {} }

# --- Helpers ---
function Wait-DockerUp {
  param([int]$TimeoutSec = 30)
  for ($i = 0; $i -lt $TimeoutSec; $i++) {
    try { docker info | Out-Null; if ($LASTEXITCODE -eq 0) { return } } catch {}
    Start-Sleep -Seconds 1
  }
  throw "Docker daemon didn't come up within $TimeoutSec seconds."
}
function Get-DockerBinPath {
  (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\docker').ImagePath
}
function Set-DockerBinPath {
  param([Parameter(Mandatory)] [string]$BinPath)
  sc.exe config docker binPath= "$BinPath" | Out-Null   # note the space after binPath=
}
function Docker-Service-Restart {
  sc.exe stop docker  | Out-Null
  sc.exe start docker | Out-Null
  Wait-DockerUp
}

# --- Core work as a scriptblock so PS7 can wrap it with Trace-Command ---
$Core = {
  param($Image, $EventLookbackMinutes)

  $originalBinPath = Get-DockerBinPath
  Write-Host "Original docker service binPath: $originalBinPath"

  try {
    # Enable dockerd debug (append --debug if missing)
    $debugBinPath = $originalBinPath
    if ($debugBinPath -notmatch '(^|\s)--debug(\s|$)') { $debugBinPath = "$debugBinPath --debug" }
    Write-Host "Setting docker service binPath (debug): $debugBinPath"
    Set-DockerBinPath -BinPath $debugBinPath
    Docker-Service-Restart

    Write-Host "Server Debug Mode check:"
    docker info | Select-String 'Debug Mode'

    Write-Host "Removing image if present: $Image"
    docker image rm $Image 2>$null

    Write-Host "Pulling image: $Image"
    docker pull $Image

    Write-Host "Collecting last $EventLookbackMinutes minutes of daemon events (untruncated)..."
    Get-WinEvent -FilterHashtable @{
        LogName      = 'Application'
        ProviderName = 'docker'
        StartTime    = (Get-Date).AddMinutes(-$EventLookbackMinutes)
      } |
      Sort-Object TimeCreated |
      Select-Object TimeCreated, Id, LevelDisplayName, @{ n='Message'; e={ $_.Message } } |
      Format-List | Out-String -Width 8192 | Write-Output

  } finally {
    Write-Host "Restoring original docker service binPath..."
    try {
      Set-DockerBinPath -BinPath $originalBinPath
      Docker-Service-Restart
    } catch {
      Write-Warning "Failed to restore docker service binPath: $($_.Exception.Message)"
    }
  }
}

# --- Run the core with per-command echoing appropriate to PS version ---
try {
  if ($PSVersionTable.PSVersion.Major -ge 7) {
    # PS 7+: use Trace-Command (Transcript will capture its output)
    Trace-Command -Name Invocation,ParameterBinding -Option All -PSHost -Expression {
      & $using:Core -ArgumentList $using:Image, $using:EventLookbackMinutes
    }
  } else {
    # PS 5.1: enable line-by-line tracing like 'set -x'
    Set-PSDebug -Trace 1
    try {
      & $Core -ArgumentList $Image, $EventLookbackMinutes
    } finally {
      Set-PSDebug -Trace 0
    }
  }
}
finally {
  Stop-Transcript-Safe
  Write-Host "=== All output saved to: $LogPath ==="
}
