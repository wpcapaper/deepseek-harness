#!/usr/bin/env bash
# Background lifecycle for `dsh web` on this checkout: start (detached, pidfile,
# readiness wait), stop (SIGTERM graceful shutdown, SIGKILL escalation),
# restart, and status. It complements the foreground `pnpm dsh web` flow.
#
# The launch line mirrors root package.json's `dsh` script — update them
# together. It runs the source-tree launcher directly (single node process), so
# the pidfile pid is the process SIGTERM must reach, with no pnpm/sh hop that
# would have to forward signals.
#
# Shutdown semantics: dsh treats SIGTERM as a supervisor stop — it disposes the
# whole plugin tree and exits 0, force-exiting itself after 5 s
# (apps/cli/src/process-shutdown.ts). `stop` sends SIGTERM, waits --timeout
# seconds (default 12), then escalates to SIGKILL.
#
# State files live in DSH_WEB_RUN_DIR (default
# ${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/dsh-web), keyed by port so several
# instances can run on different ports: dsh-web-<port>.pid / dsh-web-<port>.log.
# `--port 0` (OS-assigned) is rejected for that reason.
#
# Readiness needs curl, or bash built with /dev/tcp. macOS and Linux.

set -euo pipefail

NAME="dsh-web"
ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
RUN_DIR="${DSH_WEB_RUN_DIR:-${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/dsh-web}"
START_TIMEOUT="${DSH_WEB_START_TIMEOUT:-30}"
STOP_TIMEOUT="${DSH_WEB_STOP_TIMEOUT:-12}"

OPT_PORT="${DSH_WEB_PORT:-3080}"
OPT_HOST="${DSH_WEB_HOST:-127.0.0.1}"
OPT_FORCE=0
EXTRA_ARGS=()

usage() {
  cat <<EOF
Usage: scripts/dsh-web.sh <command> [flags] [extra \`dsh web\` args...]

Commands:
  start     launch \`dsh web\` detached (nohup), write the pidfile, wait for readiness
  stop      SIGTERM the pidfile pid and wait; SIGKILL after the grace timeout
  restart   stop, then start
  status    report pid / url / log; exit 0 when running, 1 when not

Flags:
  --port <n>      instance port; also keys the pid/log files (default: \$DSH_WEB_PORT or 3080)
  --host <h>      bind host dsh accepts (default: \$DSH_WEB_HOST or 127.0.0.1)
  --timeout <s>   stop grace seconds before SIGKILL (default: \$DSH_WEB_STOP_TIMEOUT or 12)
  --force         stop with SIGKILL immediately, skipping graceful dispose
  -h, --help      this help

Any other argument passes through to \`dsh web\` verbatim (e.g. --trusted-host host:port).

Environment:
  DSH_WEB_PORT / DSH_WEB_HOST   defaults for --port / --host
  DSH_WEB_RUN_DIR               state directory (default: \${XDG_RUNTIME_DIR:-\${TMPDIR:-/tmp}}/dsh-web)
  DSH_WEB_START_TIMEOUT         readiness wait seconds (default 30)
  DSH_WEB_STOP_TIMEOUT          stop grace seconds (default 12)
EOF
}

die() { printf '%s: error: %s\n' "$NAME" "$*" >&2; exit 1; }
info() { printf '%s: %s\n' "$NAME" "$*"; }
warn() { printf '%s: %s\n' "$NAME" "$*" >&2; }

pid_file() { printf '%s/dsh-web-%s.pid' "$RUN_DIR" "$1"; }
log_file() { printf '%s/dsh-web-%s.log' "$RUN_DIR" "$1"; }

pid_alive() { kill -0 "$1" 2>/dev/null; }

# Wait up to $2 tenths of a second for pid $1 to die; return 1 if still alive.
await_death() {
  local i=0
  while [ "$i" -lt "$2" ] && pid_alive "$1"; do
    sleep 0.1
    i=$((i + 1))
  done
  ! pid_alive "$1"
}

# Whether pid runs this checkout's dsh launcher, guarding against a reused pid.
# An empty ps reading for a pid already known live means ps is unavailable or
# blocked, not that the pid is foreign: trust the pidfile after warning. A
# readable but different command is a reused pid: refuse it.
owns_pid() {
  local cmd=""
  cmd="$(ps -p "$1" -o command= 2>/dev/null || true)"
  if [ -z "$cmd" ]; then
    warn "cannot read pid $1's command (ps unavailable or blocked); trusting the pidfile"
    return 0
  fi
  case "$cmd" in
    *apps/cli/src/bin.ts*) return 0 ;;
    *) return 1 ;;
  esac
}

# Print the pid recorded for port $1 when it names a live dsh process; drop the
# pidfile (stale, foreign, or malformed) and return 1 otherwise.
live_pid() {
  local file="$1" pid=""
  if [ -f "$file" ]; then
    pid="$(cat "$file" 2>/dev/null || true)"
    case "$pid" in '' | *[!0-9]*) pid="" ;; esac
  fi
  if [ -n "$pid" ] && pid_alive "$pid"; then
    if owns_pid "$pid"; then
      printf '%s' "$pid"
      return 0
    fi
    warn "pidfile $file holds live pid $pid that is not this checkout's dsh; dropping the stale file"
    rm -f -- "$file"
    return 1
  fi
  rm -f -- "$file"
  return 1
}

# Whether http://$1:$2/ answers; curl checks HTTP status, /dev/tcp only TCP.
http_ready() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsS --max-time 2 -o /dev/null "http://$1:$2/" >/dev/null 2>&1
  else
    (exec 3<>"/dev/tcp/$1/$2") >/dev/null 2>&1
  fi
}

parse_flags() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --port) [ $# -ge 2 ] || die "--port needs a value"; OPT_PORT=$2; shift 2 ;;
      --port=*) OPT_PORT=${1#--port=}; shift ;;
      --host) [ $# -ge 2 ] || die "--host needs a value"; OPT_HOST=$2; shift 2 ;;
      --host=*) OPT_HOST=${1#--host=}; shift ;;
      --timeout) [ $# -ge 2 ] || die "--timeout needs a value"; STOP_TIMEOUT=$2; shift 2 ;;
      --timeout=*) STOP_TIMEOUT=${1#--timeout=}; shift ;;
      --force) OPT_FORCE=1; shift ;;
      -h | --help) usage; exit 0 ;;
      *) EXTRA_ARGS+=("$1"); shift ;;
    esac
  done
}

validate_port() {
  case "$1" in '' | *[!0-9]*) die "--port must be a number (got '$1')" ;; esac
  if [ "$1" -lt 1 ] || [ "$1" -gt 65535 ]; then
    die "--port must be 1..65535 and not 0: the pid/log files are keyed by port"
  fi
}

validate_timeout() {
  case "$1" in '' | *[!0-9]*) die "--timeout must be a positive number of seconds (got '$1')" ;; esac
}

cmd_start() {
  local port="$OPT_PORT" host="$OPT_HOST" pid log extra_repr=""
  if pid="$(live_pid "$(pid_file "$port")")"; then
    info "already running: pid $pid at http://$host:$port/ (log: $(log_file "$port"))"
    return 0
  fi
  if http_ready "$host" "$port"; then
    die "something already listens on http://$host:$port/ without a $NAME pidfile — a foreground 'pnpm dsh web'? Stop it or pass --port."
  fi
  [ -f "$ROOT/apps/cli/src/bin.ts" ] || die "$ROOT/apps/cli/src/bin.ts not found — run against the deepseek-harness checkout"
  if [ -n "${EXTRA_ARGS[@]+x}" ]; then extra_repr=" ${EXTRA_ARGS[*]}"; fi
  log="$(log_file "$port")"
  printf '=== %s start %s ===\nargv: web --host %s --port %s%s\n' \
    "$NAME" "$(date '+%Y-%m-%d %H:%M:%S')" "$host" "$port" "$extra_repr" >>"$log"

  cd -- "$ROOT"
  # Same launcher line as package.json's `dsh` script; keep them in sync.
  nohup node --import tsx/esm apps/cli/src/bin.ts web \
    --host "$host" --port "$port" ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} \
    >>"$log" 2>&1 </dev/null &
  pid=$!
  printf '%s\n' "$pid" >"$(pid_file "$port")"

  local waited=0
  info "launched pid $pid; waiting up to ${START_TIMEOUT}s for http://$host:$port/"
  while [ "$waited" -lt $((START_TIMEOUT * 2)) ]; do
    if http_ready "$host" "$port"; then
      info "running at http://$host:$port/ (pid $pid)"
      info "log: $log"
      info "stop with: scripts/dsh-web.sh stop --port $port"
      return 0
    fi
    if ! pid_alive "$pid"; then
      rm -f -- "$(pid_file "$port")"
      tail -n 40 "$log" >&2 || true
      die "process exited before listening; log tail above ($log)"
    fi
    sleep 0.5
    waited=$((waited + 1))
  done
  kill -TERM "$pid" 2>/dev/null || true
  rm -f -- "$(pid_file "$port")"
  tail -n 40 "$log" >&2 || true
  die "not ready after ${START_TIMEOUT}s; sent SIGTERM to pid $pid. Raise DSH_WEB_START_TIMEOUT for slower boots. Log: $log"
}

cmd_stop() {
  local port="$OPT_PORT" pid
  if ! pid="$(live_pid "$(pid_file "$port")")"; then
    info "not running (no live pid for port $port)"
    return 0
  fi
  if [ "$OPT_FORCE" = 1 ]; then
    info "force-stopping pid $pid (SIGKILL, no graceful dispose)"
    kill -KILL "$pid" 2>/dev/null || true
  else
    info "stopping pid $pid (SIGTERM; dsh disposes gracefully, force-exits itself after 5s)"
    kill -TERM "$pid" 2>/dev/null || true
    local waited=0
    while [ "$waited" -lt $((STOP_TIMEOUT * 2)) ] && pid_alive "$pid"; do
      sleep 0.5
      waited=$((waited + 1))
    done
    if pid_alive "$pid"; then
      info "still alive after ${STOP_TIMEOUT}s; sending SIGKILL"
      kill -KILL "$pid" 2>/dev/null || true
    fi
  fi
  if ! await_death "$pid" 50; then
    rm -f -- "$(pid_file "$port")"
    die "pid $pid survived SIGKILL (uninterruptible state?); pidfile removed, inspect manually"
  fi
  rm -f -- "$(pid_file "$port")"
  info "stopped pid $pid (port $port)"
}

cmd_status() {
  local port="$OPT_PORT" host="$OPT_HOST" pid
  if ! pid="$(live_pid "$(pid_file "$port")")"; then
    info "not running (port $port)"
    return 1
  fi
  info "running: pid $pid at http://$host:$port/ (log: $(log_file "$port"))"
  if ! http_ready "$host" "$port"; then
    info "warning: pid is alive but http://$host:$port/ does not answer yet"
  fi
  return 0
}

mkdir -p -- "$RUN_DIR"
RUN_DIR="$(cd -- "$RUN_DIR" && pwd)"

if [ $# -eq 0 ]; then
  usage
  exit 0
fi
subcommand="$1"
shift
parse_flags "$@"
validate_port "$OPT_PORT"
validate_timeout "$STOP_TIMEOUT"
validate_timeout "$START_TIMEOUT"

case "$subcommand" in
  start) cmd_start ;;
  stop) cmd_stop ;;
  status) cmd_status ;;
  restart) cmd_stop; cmd_start ;;
  -h | --help | help) usage ;;
  *)
    printf '%s: error: unknown command %s\n' "$NAME" "$subcommand" >&2
    usage >&2
    exit 2
    ;;
esac
