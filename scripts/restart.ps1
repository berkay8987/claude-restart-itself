param(
  [string]$Session = 'last',
  [switch]$Detached,
  [switch]$DryRun
)

$ErrorActionPreference = 'SilentlyContinue'

$log = Join-Path $env:TEMP 'restart-claude.log'
function Note($m) { "$(Get-Date -Format o) [$PID] $m" | Out-File -FilePath $log -Append -Encoding utf8 }

# The app runs its children inside a job object, and killing the app tears the
# whole job down -- a Start-Process child dies with it. A process created
# through WMI is parented to WmiPrvSE and is outside the job, so it survives.
if (-not $Detached) {
  Note "bootstrap (session=$Session, dryrun=$DryRun)"
  $self = $PSCommandPath
  $cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$self`" -Session $Session -Detached"
  if ($DryRun) { $cmd = $cmd + ' -DryRun' }
  $res = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $cmd }
  Note "handed off via WMI rv=$($res.ReturnValue) pid=$($res.ProcessId)"
  exit 0
}

Note "detached start (session=$Session, dryrun=$DryRun)"

$pkg = Get-AppxPackage -Name 'Claude' | Select-Object -First 1
if (-not $pkg) { Note 'Claude package not found; aborting'; exit 1 }
$install = $pkg.InstallLocation
$family = $pkg.PackageFamilyName
Note "install=$install family=$family"

# The app's own processes, plus the claude-code engines it spawned.
function Targets {
  Get-Process -Name claude -ErrorAction SilentlyContinue | Where-Object {
    $_.Path -and (
      $_.Path.StartsWith($install, [System.StringComparison]::OrdinalIgnoreCase) -or
      $_.Path -like '*\Claude-Data\*\claude-code\*'
    )
  }
}

$url = "claude://code/continue?session=$Session"

if ($DryRun) {
  Note "DRY RUN: would close $(@(Targets).Count) process(es), then launch $url"
  exit 0
}

# Ask nicely first, so the app saves its state.
foreach ($p in @(Targets)) { $null = $p.CloseMainWindow() }

$deadline = (Get-Date).AddSeconds(8)
while ((Get-Date) -lt $deadline) {
  if (@(Targets).Count -eq 0) { break }
  Start-Sleep -Milliseconds 250
}

$left = @(Targets)
if ($left.Count -gt 0) {
  Note "forcing $($left.Count) leftover process(es)"
  foreach ($p in $left) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
}

# Wait for the process table to actually clear, so the relaunch is a cold start.
$deadline = (Get-Date).AddSeconds(10)
while ((Get-Date) -lt $deadline) {
  if (@(Targets).Count -eq 0) { break }
  Start-Sleep -Milliseconds 250
}
Note "after kill: $(@(Targets).Count) still up"

# Let Windows release the package's single-instance lock.
Start-Sleep -Milliseconds 2000

function IsUp { @(Get-Process -Name claude -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($install, [System.StringComparison]::OrdinalIgnoreCase) }).Count -gt 0 }

function WaitUp([int]$seconds) {
  $d = (Get-Date).AddSeconds($seconds)
  while ((Get-Date) -lt $d) {
    if (IsUp) { return $true }
    Start-Sleep -Milliseconds 400
  }
  return $false
}

Note "launching $url"
Start-Process $url
if (WaitUp 10) { Note 'up (deep link)'; exit 0 }

# ShellExecute from a WMI-parented process can miss the desktop; explorer is
# already on it and handles both protocol and package activation.
Note 'deep link did not take; trying explorer with the url'
Start-Process 'explorer.exe' -ArgumentList $url
if (WaitUp 10) { Note 'up (explorer url)'; exit 0 }

Note 'still down; launching the package directly'
Start-Process 'explorer.exe' -ArgumentList "shell:AppsFolder\$family!Claude"
if (WaitUp 15) { Note 'up (package)'; exit 0 }

Note 'FAILED: app did not come back'
exit 1
