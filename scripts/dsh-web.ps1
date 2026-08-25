# dsh-web.ps1 -- background lifecycle for `dsh web` on this checkout (Windows
# PowerShell 5.1 and PowerShell 7+): start (detached, pidfile, readiness wait),
# stop, restart, status. It complements the foreground `pnpm dsh web` flow and
# is the Windows counterpart of scripts/dsh-web.sh, kept intentionally simpler:
# logs go to dsh-web-<port>.log (stdout) and dsh-web-<port>.err.log (stderr).
#
# The launch line mirrors root package.json's `dsh` script -- update them
# together. Windows has no SIGTERM, so `stop` terminates the process directly;
# on pwsh for macOS/Linux `Stop-Process` sends SIGTERM (graceful dispose) and
# `-Force` escalates to SIGKILL after --timeout, matching dsh-web.sh.
#
# State files live in $env:DSH_WEB_RUN_DIR (default %TEMP%\dsh-web), keyed by
# port so several instances can run on different ports: dsh-web-<port>.pid /
# .log / .err.log. --port 0 (OS-assigned) is rejected.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$NAME = 'dsh-web'
$ROOT = Split-Path -Parent $PSScriptRoot
$script:IsWindows = $PSVersionTable.PSEdition -eq 'Desktop' -or
  [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT

if ($env:DSH_WEB_RUN_DIR) {
  $script:RUN_DIR = [System.IO.Path]::GetFullPath($env:DSH_WEB_RUN_DIR)
} elseif ($script:IsWindows) {
  $script:RUN_DIR = [System.IO.Path]::GetFullPath((Join-Path $env:TEMP 'dsh-web'))
} elseif ($env:TMPDIR) {
  $script:RUN_DIR = [System.IO.Path]::GetFullPath((Join-Path $env:TMPDIR 'dsh-web'))
} else {
  $script:RUN_DIR = [System.IO.Path]::GetFullPath('/tmp/dsh-web')
}

$script:OPT_PORT = if ($env:DSH_WEB_PORT) { $env:DSH_WEB_PORT } else { '3080' }
$script:OPT_HOST = if ($env:DSH_WEB_HOST) { $env:DSH_WEB_HOST } else { '127.0.0.1' }
$script:START_TIMEOUT = if ($env:DSH_WEB_START_TIMEOUT) { $env:DSH_WEB_START_TIMEOUT } else { '30' }
$script:STOP_TIMEOUT = if ($env:DSH_WEB_STOP_TIMEOUT) { $env:DSH_WEB_STOP_TIMEOUT } else { '12' }
$script:EXTRA_ARGS = [System.Collections.Generic.List[string]]::new()

function usage {
  @'
Usage: scripts/dsh-web.ps1 <command> [flags] [extra `dsh web` args...]

Commands:
  start     launch `dsh web` detached, write the pidfile, wait for readiness
  stop      stop the pidfile pid (terminate on Windows; SIGTERM then SIGKILL on pwsh for macOS/Linux)
  restart   stop, then start
  status    report pid / url / logs; exit 0 when running, 1 when not

Flags:
  --port <n>      instance port; also keys the pid/log files (default: $env:DSH_WEB_PORT or 3080)
  --host <h>      bind host dsh accepts (default: $env:DSH_WEB_HOST or 127.0.0.1)
  --timeout <s>   stop grace seconds before the hard kill (default: $env:DSH_WEB_STOP_TIMEOUT or 12)
  -h, --help      this help

Any other argument passes through to `dsh web` verbatim (e.g. --trusted-host host:port).

Environment:
  DSH_WEB_PORT / DSH_WEB_HOST   defaults for --port / --host
  DSH_WEB_RUN_DIR               state directory (default: %TEMP%\dsh-web)
  DSH_WEB_START_TIMEOUT         readiness wait seconds (default 30)
  DSH_WEB_STOP_TIMEOUT          stop grace seconds (default 12)
'@
}

function die([string]$Msg) {
  [Console]::Error.WriteLine("${NAME}: error: $Msg")
  exit 1
}
function info([string]$Msg) {
  Write-Output "${NAME}: $Msg"
}
function tail_log([string]$Log) {
  Get-Content -Path $Log -Tail 40 -ErrorAction SilentlyContinue |
    ForEach-Object { [Console]::Error.WriteLine($_) }
}

function pid_file([string]$Port) { Join-Path $RUN_DIR "dsh-web-$Port.pid" }
function log_file([string]$Port) { Join-Path $RUN_DIR "dsh-web-$Port.log" }
function err_log_file([string]$Port) { Join-Path $RUN_DIR "dsh-web-$Port.err.log" }

function pid_alive([int]$ProcessId) {
  $null -ne (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)
}

# The pid recorded in $File when it names a live process; drop the pidfile
# (stale or malformed) and return $null otherwise.
function live_pid([string]$File) {
  $found = ''
  if (Test-Path -LiteralPath $File) {
    $raw = Get-Content -LiteralPath $File -Raw -ErrorAction SilentlyContinue
    if ($null -ne $raw -and ($raw.Trim() -match '^[0-9]+$')) { $found = $raw.Trim() }
  }
  if ($found -ne '' -and (pid_alive ([int]$found))) { return [int]$found }
  Remove-Item -LiteralPath $File -Force -ErrorAction SilentlyContinue
  return $null
}

# Whether http://$Addr:$Port/ answers with any HTTP status.
function http_ready([string]$Addr, [string]$Port) {
  try {
    $params = @{ Uri = "http://$Addr`:$Port/"; TimeoutSec = 2 }
    if ($PSVersionTable.PSVersion.Major -lt 6) { $params.UseBasicParsing = $true }
    Invoke-WebRequest @params | Out-Null
    return $true
  } catch { return $false }
}

# Wait up to $Tenths tenths of a second for process $ProcessId to die; false if
# still alive.
function await_death([int]$ProcessId, [int]$Tenths) {
  $i = 0
  while ($i -lt $Tenths -and (pid_alive $ProcessId)) {
    Start-Sleep -Milliseconds 100
    $i++
  }
  -not (pid_alive $ProcessId)
}

function parse_flags([string[]]$ArgsList) {
  $i = 0
  while ($i -lt $ArgsList.Count) {
    $a = $ArgsList[$i]
    if ($a -eq '--port') {
      if ($i + 1 -ge $ArgsList.Count) { die '--port needs a value' }
      $script:OPT_PORT = $ArgsList[$i + 1]
      $i += 2
    } elseif ($a -like '--port=*') {
      $script:OPT_PORT = $a.Substring(7)
      $i++
    } elseif ($a -eq '--host') {
      if ($i + 1 -ge $ArgsList.Count) { die '--host needs a value' }
      $script:OPT_HOST = $ArgsList[$i + 1]
      $i += 2
    } elseif ($a -like '--host=*') {
      $script:OPT_HOST = $a.Substring(7)
      $i++
    } elseif ($a -eq '--timeout') {
      if ($i + 1 -ge $ArgsList.Count) { die '--timeout needs a value' }
      $script:STOP_TIMEOUT = $ArgsList[$i + 1]
      $i += 2
    } elseif ($a -like '--timeout=*') {
      $script:STOP_TIMEOUT = $a.Substring(10)
      $i++
    } elseif ($a -eq '-h' -or $a -eq '--help') {
      usage
      exit 0
    } else {
      $script:EXTRA_ARGS.Add($a)
      $i++
    }
  }
}

function Assert-Digits([string]$Value, [string]$What) {
  if ($Value -notmatch '^[0-9]+$') { die "$What must be a number (got '$Value')" }
}

function Assert-Port([string]$Value) {
  Assert-Digits $Value '--port'
  $n = [int]$Value
  if ($n -lt 1 -or $n -gt 65535) {
    die '--port must be 1..65535 and not 0: the pid/log files are keyed by port'
  }
}

function Assert-Timeout([string]$Value) {
  Assert-Digits $Value '--timeout'
  return [int]$Value
}

function cmd_start {
  $port = $OPT_PORT
  $addr = $OPT_HOST
  $file = pid_file $port
  $log = log_file $port
  $errLog = err_log_file $port
  if ($null -ne (live_pid $file)) {
    info "already running (see the pidfile $file)"
    return
  }
  if (http_ready $addr $port) {
    die "something already listens on http://$addr`:$port/ without a $NAME pidfile -- a foreground 'pnpm dsh web'? Stop it or pass --port."
  }
  if (-not (Test-Path -LiteralPath (Join-Path $ROOT 'apps/cli/src/bin.ts'))) {
    die "$ROOT/apps/cli/src/bin.ts not found -- run against the deepseek-harness checkout"
  }
  $extraRepr = ''
  if ($EXTRA_ARGS.Count -gt 0) { $extraRepr = ' ' + ($EXTRA_ARGS -join ' ') }
  $header = "=== $NAME start $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ===`nargv: web --host $addr --port $port$extraRepr`n"
  [System.IO.File]::AppendAllText($log, $header)
  [System.IO.File]::AppendAllText($errLog, $header)

  $nodeCmd = Get-Command node -CommandType Application -ErrorAction SilentlyContinue
  if ($null -eq $nodeCmd) { die 'node not found in PATH (required: ^22.19 || >=24)' }
  $nodeExe = $nodeCmd.Source

  # Same launcher line as package.json's `dsh` script; keep them in sync.
  $argList = [System.Collections.Generic.List[string]]::new()
  foreach ($a in @('--import', 'tsx/esm', 'apps/cli/src/bin.ts', 'web', '--host', $addr, '--port', $port) + $EXTRA_ARGS) {
    $argList.Add($a)
  }
  $joinedArgs = (($argList | ForEach-Object {
    if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
  }) -join ' ')

  $proc = Start-Process -FilePath $nodeExe -ArgumentList $joinedArgs -WorkingDirectory $ROOT `
    -RedirectStandardOutput $log -RedirectStandardError $errLog -PassThru -WindowStyle Hidden
  [System.IO.File]::WriteAllText($file, "$($proc.Id)`n")

  $waited = 0
  info "launched pid $($proc.Id); waiting up to ${START_TIMEOUT}s for http://$addr`:$port/"
  while ($waited -lt ($START_TIMEOUT * 2)) {
    if (http_ready $addr $port) {
      info "running at http://$addr`:$port/ (pid $($proc.Id))"
      info "logs: $log / $errLog"
      info "stop with: scripts/dsh-web.ps1 stop --port $port"
      return
    }
    if ($proc.HasExited) {
      Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
      tail_log $errLog
      tail_log $log
      die "process exited before listening; log tails above"
    }
    Start-Sleep -Milliseconds 500
    $waited++
  }
  Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
  tail_log $errLog
  tail_log $log
  die "not ready after ${START_TIMEOUT}s; stopped pid $($proc.Id). Raise DSH_WEB_START_TIMEOUT for slower boots."
}

function cmd_stop {
  $port = $OPT_PORT
  $file = pid_file $port
  $webPid = live_pid $file
  if ($null -eq $webPid) {
    info "not running (no live pid for port $port)"
    return
  }
  if ($script:IsWindows) {
    info "stopping pid $webPid (terminating; Windows has no SIGTERM, so dsh cannot dispose gracefully)"
    Stop-Process -Id $webPid -Force -ErrorAction SilentlyContinue
  } else {
    info "stopping pid $webPid (SIGTERM; dsh disposes gracefully, force-exits itself after 5s)"
    Stop-Process -Id $webPid -ErrorAction SilentlyContinue
    $waited = 0
    while ($waited -lt ($STOP_TIMEOUT * 2) -and (pid_alive $webPid)) {
      Start-Sleep -Milliseconds 500
      $waited++
    }
    if (pid_alive $webPid) {
      info "still alive after ${STOP_TIMEOUT}s; sending SIGKILL"
      Stop-Process -Id $webPid -Force -ErrorAction SilentlyContinue
    }
  }
  if (-not (await_death $webPid 50)) {
    Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    die 'pid survived termination (uninterruptible state?); pidfile removed, inspect manually'
  }
  Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
  info "stopped pid $webPid (port $port)"
}

function cmd_status {
  $port = $OPT_PORT
  $addr = $OPT_HOST
  $file = pid_file $port
  $log = log_file $port
  $errLog = err_log_file $port
  $webPid = live_pid $file
  if ($null -eq $webPid) {
    info "not running (port $port)"
    exit 1
  }
  info "running: pid $webPid at http://$addr`:$port/ (logs: $log / $errLog)"
  if (-not (http_ready $addr $port)) {
    info "warning: pid is alive but http://$addr`:$port/ does not answer yet"
  }
}

New-Item -ItemType Directory -Force -Path $RUN_DIR | Out-Null

$all = @($args)
if ($all.Count -eq 0) {
  usage
  exit 0
}
$subcommand = $all[0]
$rest = @()
if ($all.Count -gt 1) { $rest = $all[1..($all.Count - 1)] }
parse_flags $rest
Assert-Port $OPT_PORT
$script:STOP_TIMEOUT = Assert-Timeout $STOP_TIMEOUT
$script:START_TIMEOUT = Assert-Timeout $START_TIMEOUT

switch ($subcommand) {
  'start' { cmd_start }
  'stop' { cmd_stop }
  'restart' { cmd_stop; cmd_start }
  'status' { cmd_status }
  '-h' { usage }
  '--help' { usage }
  'help' { usage }
  default {
    [Console]::Error.WriteLine("${NAME}: error: unknown command $subcommand")
    [Console]::Error.WriteLine((usage))
    exit 2
  }
}
