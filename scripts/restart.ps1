param(
  [string]$Session = 'last',
  [int]$GraceMs = 600,
  [int]$SettleMs = 1200,
  [int]$MinUptimeMs = 6000,
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
  $cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$self`" -Session $Session -GraceMs $GraceMs -SettleMs $SettleMs -MinUptimeMs $MinUptimeMs -Detached"
  if ($DryRun) { $cmd = $cmd + ' -DryRun' }
  $res = New-DetachedProcess $cmd
  Note "handed off via WMI rv=$($res.ReturnValue) pid=$($res.ProcessId)"
  exit 0
}

Note "detached start (session=$Session, grace=${GraceMs}ms, settle=${SettleMs}ms)"

# Windows only lets a process raise a window if it owns the foreground, and
# nothing in this chain does: the helper is parented to WmiPrvSE with no input
# of its own. Left alone the restarted app lands behind everything with its
# taskbar button lit, waiting for a click. These let it be pulled forward.
Add-Type -Namespace Fg -Name Win -MemberDefinition @"
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
[DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);
[DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
[DllImport("user32.dll")] public static extern void SwitchToThisWindow(IntPtr hWnd, bool fAltTab);
[DllImport("user32.dll")] public static extern bool AllowSetForegroundWindow(int dwProcessId);
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
[DllImport("user32.dll")] public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
[DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
"@

function Raise-Window([IntPtr]$hwnd) {
  # SW_RESTORE un-maximises a maximised window, so only use it on a minimised
  # one. The app restores its own size and state; this must not override it.
  if ([Fg.Win]::IsIconic($hwnd)) {
    $SW_RESTORE = 9
    $null = [Fg.Win]::ShowWindowAsync($hwnd, $SW_RESTORE)
  }

  # Borrow the foreground thread's input state so the raise is permitted.
  $fore = [Fg.Win]::GetForegroundWindow()
  $null = 0
  $foreThread = [Fg.Win]::GetWindowThreadProcessId($fore, [ref]$null)
  $ownThread = [Fg.Win]::GetCurrentThreadId()
  $attached = $false
  if ($foreThread -ne 0 -and $foreThread -ne $ownThread) {
    $attached = [Fg.Win]::AttachThreadInput($ownThread, $foreThread, $true)
  }
  $null = [Fg.Win]::SetForegroundWindow($hwnd)
  [Fg.Win]::SwitchToThisWindow($hwnd, $true)
  if ($attached) { $null = [Fg.Win]::AttachThreadInput($ownThread, $foreThread, $false) }
}


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

function Focus-Claude([string]$InstallPath) {
  # The process exists well before it has a window; wait for one, then raise it.
  $deadline = (Get-Date).AddSeconds(20)
  while ((Get-Date) -lt $deadline) {
    $win = Get-Process -Name claude -ErrorAction SilentlyContinue | Where-Object {
      $_.Path -and $_.Path.StartsWith($InstallPath, [System.StringComparison]::OrdinalIgnoreCase) -and $_.MainWindowHandle -ne 0
    } | Select-Object -First 1
    if ($win) {
      Raise-Window $win.MainWindowHandle
      Note "raised window of pid $($win.Id)"

      return
    }
    Start-Sleep -Milliseconds 100
  }
  Note 'no main window appeared to raise'
}

$url = "claude://code/continue?session=$Session"

if ($DryRun) {
  Note "DRY RUN: would close $(@(Targets).Count) process(es), then launch $url"
  exit 0
}

# Killing the app while it is still starting leaves it half-initialised, and the
# next launch can come up without its plugins. On a back-to-back restart the app
# is only seconds old, so wait until it has had time to finish before killing it.
# The app's own launch time is its OLDEST process; the claude-code engines come
# and go per session, so the youngest process says nothing about app uptime.
$appStart = @(Get-Process -Name claude -ErrorAction SilentlyContinue | Where-Object {
  $_.Path -and $_.Path.StartsWith($install, [System.StringComparison]::OrdinalIgnoreCase) -and $_.StartTime
} | Sort-Object StartTime | Select-Object -First 1)
if ($appStart.Count -gt 0) {
  $ageMs = ((Get-Date) - $appStart[0].StartTime).TotalMilliseconds
  if ($ageMs -lt $MinUptimeMs) {
    $waitMs = [int]($MinUptimeMs - $ageMs)
    Note "app is only $([int]$ageMs)ms old; waiting ${waitMs}ms so it finishes starting"
    Start-Sleep -Milliseconds $waitMs
  }
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
# The package needs a moment after its last process goes before Windows will
# activate it again. Fire the deep link too early and the shell has no handler
# to give it to: it opens a plain File Explorer window instead, and the app can
# come up without its plugins. This settle window is the price of that; it is
# measured in the log, so it can be tuned rather than guessed at.
Start-Sleep -Milliseconds $SettleMs

# ASFW_ANY: waive our claim so the app being started may take the foreground.
$null = [Fg.Win]::AllowSetForegroundWindow(-1)

foreach ($attempt in 1..2) {
  $res = New-DetachedProcess "explorer.exe `"$url`""
  Note "activation attempt $attempt rv=$($res.ReturnValue)"
  $deadline = (Get-Date).AddMilliseconds(2500)
  while ((Get-Date) -lt $deadline) {
    if (IsUp) {
      Note "up (explorer url, attempt $attempt)"
      Focus-Claude $install
      exit 0
    }
    Start-Sleep -Milliseconds 50
  }
}

Note 'explorer did not take; launching the package directly'
$res = New-DetachedProcess "explorer.exe `"shell:AppsFolder\$family!Claude`""
$deadline = (Get-Date).AddSeconds(15)
while ((Get-Date) -lt $deadline) {
  if (IsUp) { Note 'up (package)'; Focus-Claude $install; exit 0 }
  Start-Sleep -Milliseconds 100
}

Note 'FAILED: app did not come back'
exit 1
