param(
  [string]$Session = 'last',
  [int]$GraceMs = 600,
  [switch]$Detached,
  [switch]$DryRun
)

$ErrorActionPreference = 'SilentlyContinue'

$log = Join-Path $env:TEMP 'restart-claude.log'
$t0 = Get-Date
function Note($m) {
  $ms = [int]((Get-Date) - $t0).TotalMilliseconds
  "$(Get-Date -Format o) [$PID] +${ms}ms $m" | Out-File -FilePath $log -Append -Encoding utf8
}

# Create a process outside this app's job object (see below), console hidden.
function New-DetachedProcess([string]$CommandLine) {
  $startup = New-CimInstance -ClassName Win32_ProcessStartup -ClientOnly -Property @{ ShowWindow = [uint16]0 }

  return Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
    CommandLine               = $CommandLine
    ProcessStartupInformation = $startup
  }
}

# The app runs its children inside a job object, and killing the app tears the
# whole job down -- a Start-Process child dies with it. A process created
# through WMI is parented to WmiPrvSE and is outside the job, so it survives.
if (-not $Detached) {
  Note "bootstrap (session=$Session, dryrun=$DryRun)"
  $self = $PSCommandPath
  $cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$self`" -Session $Session -GraceMs $GraceMs -Detached"
  if ($DryRun) { $cmd = $cmd + ' -DryRun' }
  $res = New-DetachedProcess $cmd
  Note "handed off via WMI rv=$($res.ReturnValue) pid=$($res.ProcessId)"
  exit 0
}

Note "detached start (session=$Session, grace=${GraceMs}ms)"

$pkg = Get-AppxPackage -Name 'Claude' | Select-Object -First 1
if (-not $pkg) { Note 'Claude package not found; aborting'; exit 1 }
$install = $pkg.InstallLocation
$family = $pkg.PackageFamilyName

# The app's own processes, plus the claude-code engines it spawned.
function Targets {
  Get-Process -Name claude -ErrorAction SilentlyContinue | Where-Object {
    $_.Path -and (
      $_.Path.StartsWith($install, [System.StringComparison]::OrdinalIgnoreCase) -or
      $_.Path -like '*\Claude-Data\*\claude-code\*'
    )
  }
}

function IsUp {
  @(Get-Process -Name claude -ErrorAction SilentlyContinue | Where-Object {
    $_.Path -and $_.Path.StartsWith($install, [System.StringComparison]::OrdinalIgnoreCase)
  }).Count -gt 0
}

$url = "claude://code/continue?session=$Session"

if ($DryRun) {
  Note "DRY RUN: would close $(@(Targets).Count) process(es), then launch $url"
  exit 0
}

# A courtesy close, then force. Measured over many runs, every process always
# ends up force-killed anyway, so the grace window is kept short on purpose:
# waiting the old eight seconds bought nothing but eight seconds.
foreach ($p in @(Targets)) { if ($p.MainWindowHandle -ne 0) { $null = $p.CloseMainWindow() } }

$deadline = (Get-Date).AddMilliseconds($GraceMs)
while ((Get-Date) -lt $deadline -and @(Targets).Count -gt 0) { Start-Sleep -Milliseconds 50 }

$left = @(Targets)
if ($left.Count -gt 0) {
  foreach ($p in $left) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
}

# Wait for the table to clear, polling tightly rather than sleeping a constant.
$deadline = (Get-Date).AddSeconds(10)
while ((Get-Date) -lt $deadline -and @(Targets).Count -gt 0) { Start-Sleep -Milliseconds 50 }
Note "killed ($($left.Count) forced); $(@(Targets).Count) still up"

# Hand the activation to explorer, which passes it to the running shell and
# exits. Starting the app from here instead would leave it sharing this
# process's console: its stdout would appear in a stray PowerShell window, and
# closing that window would close the app with it.
#
# The package's single-instance lock may not be released the instant the last
# process goes, so retry rather than sleeping a fixed guess up front.
foreach ($attempt in 1..3) {
  $res = New-DetachedProcess "explorer.exe `"$url`""
  Note "activation attempt $attempt rv=$($res.ReturnValue)"
  $deadline = (Get-Date).AddMilliseconds(2500)
  while ((Get-Date) -lt $deadline) {
    if (IsUp) { Note "up (explorer url, attempt $attempt)"; exit 0 }
    Start-Sleep -Milliseconds 50
  }
}

Note 'explorer did not take; launching the package directly'
$res = New-DetachedProcess "explorer.exe `"shell:AppsFolder\$family!Claude`""
$deadline = (Get-Date).AddSeconds(15)
while ((Get-Date) -lt $deadline) {
  if (IsUp) { Note 'up (package)'; exit 0 }
  Start-Sleep -Milliseconds 100
}

Note 'FAILED: app did not come back'
exit 1
