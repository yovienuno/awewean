#!/usr/bin/env bash
set -Eeuo pipefail

# Seine (Blocknet) runner with optional WSS relay (Cloudflare Worker or Render).
#
# Place this script beside ./seine and cf-relay-bridge.py.
#
# Direct mode:
#   sudo ./a.sh --mode direct
#
# Relay mode (default): Seine only speaks raw stratum TCP, so this starts a
# local TCP -> WSS bridge and points Seine at 127.0.0.1. The relay host then
# opens the real TCP connection to the pool.
#   sudo ./a.sh --mode relay --relay wss://worker.example.workers.dev/bntpool
#   sudo ./a.sh --mode relay --relay 'wss://relay.example.onrender.com/bntpool?token=...'
#
# This script does NOT download or extract anything.

# ----------------------------- configuration -----------------------------

ADDRESS="${ADDRESS:-7eseCPTmrS9bmYs4oonUq3WjMxTW8nsY3ueyYCBCT6BTWiWAxHGKmMEaGuUexXXxzYUWt95NmnxZMvQC5GLqcDEzQJEWm}"

# relay | direct
MODE="${MODE:-relay}"

# Direct pool endpoint. Also the default pool behind the relay.
POOL_URL="${POOL_URL:-stratum+tcp://bntpool.com:3333}"

# WSS relay settings (Cloudflare Worker custom domain or Render).
RELAY_URL="${RELAY_URL:-wss://relay.saamaaeel.my.id/bntpool}"
RELAY_TARGET="${RELAY_TARGET:-bntpool.com:3333}"
RELAY_LOCAL_PORT="${RELAY_LOCAL_PORT:-33333}"
RELAY_CHECK="${RELAY_CHECK:-1}"   # 1 = verify relay -> pool before mining
RELAY_CHECK_TIMEOUT="${RELAY_CHECK_TIMEOUT:-90}"  # allow a cold Render free instance to wake

# CPU / huge pages. Each Seine CPU worker hashes in a 2 GiB arena, backed by
# 1024 x 2 MiB HugeTLB pages. Keep CPU_THREADS in sync with the reservation.
CPU_THREADS="${CPU_THREADS:-1}"
CPU_PAGE_MODE="${CPU_PAGE_MODE:-auto}"
POOL_WORKER="${POOL_WORKER:-$(printf 'w%04x%04x' "$RANDOM" "$RANDOM")}"

HUGEPAGES_PER_THREAD="${HUGEPAGES_PER_THREAD:-1024}"
HUGEPAGES_HEADROOM_PERCENT="${HUGEPAGES_HEADROOM_PERCENT:-0}"
HUGEPAGES_TARGET="${HUGEPAGES_TARGET:-}"
SYSCTL_CONF="${SYSCTL_CONF:-/etc/sysctl.d/99-seine-hugepages.conf}"

# ------------------------------- helpers ---------------------------------

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

prog="$(basename -- "${BASH_SOURCE[0]}")"

usage() {
  cat <<EOF
Usage: sudo ./${prog} [options]

Connection:
  --mode relay|direct     relay (default) or direct pool connection
  --relay URL             WSS relay URL (Cloudflare or Render)
  --target HOST:PORT      pool behind the Worker (default: ${RELAY_TARGET})
  --pool URL              direct pool URL (default: ${POOL_URL})
  --local-port PORT       local TCP port for the relay bridge (default: ${RELAY_LOCAL_PORT})
  --no-check              skip the relay -> pool probe
  --check                 force the relay -> pool probe

Mining:
  --address ADDRESS       payout address
  --threads N             CPU threads / workers (default: ${CPU_THREADS})
  --page-mode MODE        auto, regular, large, or large-1g (default: ${CPU_PAGE_MODE})
  --pool-worker NAME      worker name sent to the pool

Other:
  -h, --help              show this help
EOF
}

# Parse command-line overrides after the defaults above.
while (($# > 0)); do
  case "$1" in
    --mode)
      MODE="${2:?--mode needs a value}"
      shift 2
      ;;
    --relay)
      RELAY_URL="${2:?--relay needs a value}"
      shift 2
      ;;
    --target)
      RELAY_TARGET="${2:?--target needs a value}"
      shift 2
      ;;
    --pool)
      POOL_URL="${2:?--pool needs a value}"
      shift 2
      ;;
    --local-port)
      RELAY_LOCAL_PORT="${2:?--local-port needs a value}"
      shift 2
      ;;
    --address)
      ADDRESS="${2:?--address needs a value}"
      shift 2
      ;;
    --threads)
      CPU_THREADS="${2:?--threads needs a value}"
      shift 2
      ;;
    --page-mode)
      CPU_PAGE_MODE="${2:?--page-mode needs a value}"
      shift 2
      ;;
    --pool-worker)
      POOL_WORKER="${2:?--pool-worker needs a value}"
      shift 2
      ;;
    --check)
      RELAY_CHECK=1
      shift
      ;;
    --no-check)
      RELAY_CHECK=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1 (use --help)"
      ;;
  esac
done

case "$MODE" in
  relay|direct) ;;
  *) die "MODE/--mode must be relay or direct, got: $MODE" ;;
esac

case "$RELAY_CHECK" in
  0|1) ;;
  *) die "RELAY_CHECK/--check must be 0 or 1" ;;
esac

[[ "$CPU_THREADS" =~ ^[1-9][0-9]*$ ]] \
  || die "CPU_THREADS/--threads must be a positive integer."
[[ "$HUGEPAGES_PER_THREAD" =~ ^[1-9][0-9]*$ ]] \
  || die "HUGEPAGES_PER_THREAD must be a positive integer."
[[ "$HUGEPAGES_HEADROOM_PERCENT" =~ ^[0-9]+$ ]] \
  || die "HUGEPAGES_HEADROOM_PERCENT must be an integer from 0 to 100."
(( HUGEPAGES_HEADROOM_PERCENT <= 100 )) \
  || die "HUGEPAGES_HEADROOM_PERCENT must be an integer from 0 to 100."
[[ "$RELAY_LOCAL_PORT" =~ ^[0-9]+$ ]] \
  || die "RELAY_LOCAL_PORT/--local-port must be a number."
(( RELAY_LOCAL_PORT >= 1024 && RELAY_LOCAL_PORT <= 65535 )) \
  || die "RELAY_LOCAL_PORT/--local-port must be between 1024 and 65535."
[[ "$RELAY_CHECK_TIMEOUT" =~ ^[1-9][0-9]*$ ]] \
  || die "RELAY_CHECK_TIMEOUT must be a positive integer."

case "$CPU_PAGE_MODE" in
  auto|regular|large|large-1g) ;;
  *) die "CPU_PAGE_MODE/--page-mode must be auto, regular, large, or large-1g." ;;
esac

[[ -n "$ADDRESS" ]] || die "ADDRESS/--address cannot be empty."

if [[ "$MODE" == 'relay' ]]; then
  [[ -n "$RELAY_URL" ]] || die "Relay mode needs RELAY_URL/--relay."
  [[ "$RELAY_URL" == ws://* || "$RELAY_URL" == wss://* ]] \
    || die "RELAY_URL must start with ws:// or wss://."
  [[ -n "$RELAY_TARGET" ]] || die "Relay mode needs RELAY_TARGET/--target."
fi

# -------------------------- files / permissions --------------------------

# Persisting /etc/sysctl.d settings and adjusting vm.nr_hugepages require root.
if [[ "${EUID}" -ne 0 ]]; then
  die "Run as root, for example: sudo ./${prog}"
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MINER="${SCRIPT_DIR}/seine"
BRIDGE="${SCRIPT_DIR}/cf-relay-bridge.py"
BRIDGE_LOG="${SCRIPT_DIR}/cf-relay-bridge.log"

[[ -f "$MINER" ]] \
  || die "Cannot find the existing Seine binary at: $MINER. Put ${prog} beside ./seine."
if [[ ! -x "$MINER" ]]; then
  log 'seine is not executable; adding execute permission.'
  chmod +x "$MINER" || die 'Could not make seine executable.'
fi

if [[ "$MODE" == 'relay' ]]; then
  command -v python3 >/dev/null 2>&1 \
    || die 'Relay mode needs python3 (apt install python3).'
  [[ -f "$BRIDGE" ]] \
    || die "Cannot find ${BRIDGE}. Keep cf-relay-bridge.py beside ${prog}."
fi

# ------------------------------- cleanup ---------------------------------

TMP_CONF=''
BRIDGE_PID=''

cleanup() {
  if [[ -n "$TMP_CONF" ]]; then
    rm -f -- "$TMP_CONF"
    TMP_CONF=''
  fi
  if [[ -n "$BRIDGE_PID" ]] && kill -0 "$BRIDGE_PID" 2>/dev/null; then
    log 'Stopping relay bridge.'
    kill "$BRIDGE_PID" 2>/dev/null || true
    wait "$BRIDGE_PID" 2>/dev/null || true
  fi
  BRIDGE_PID=''
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# ------------------------------ huge pages -------------------------------

HUGEPAGES_REQUIRED=$((CPU_THREADS * HUGEPAGES_PER_THREAD))
if [[ -n "$HUGEPAGES_TARGET" ]]; then
  [[ "$HUGEPAGES_TARGET" =~ ^[0-9]+$ ]] \
    || die "HUGEPAGES_TARGET must be a number."
  (( HUGEPAGES_TARGET >= HUGEPAGES_REQUIRED )) \
    || die "HUGEPAGES_TARGET=${HUGEPAGES_TARGET} is below the ${HUGEPAGES_REQUIRED} pages needed for ${CPU_THREADS} thread(s)."
else
  HUGEPAGES_TARGET=$(( (HUGEPAGES_REQUIRED * (100 + HUGEPAGES_HEADROOM_PERCENT) + 99) / 100 ))
fi

# Read HugeTLB values from /proc/meminfo without relying on localized output.
huge_total() { awk '/^HugePages_Total:/ {print $2}' /proc/meminfo; }
huge_free()  { awk '/^HugePages_Free:/  {print $2}' /proc/meminfo; }
huge_size()  { awk '/^Hugepagesize:/    {print $2}' /proc/meminfo; }
mem_avail()  { awk '/^MemAvailable:/    {print $2}' /proc/meminfo; }

page_size="$(huge_size)"
[[ "$page_size" == '2048' ]] \
  || die "Expected 2048 kB HugeTLB pages, but system reports ${page_size:-unknown} kB."

log "Reserving ${HUGEPAGES_TARGET} huge pages for ${CPU_THREADS} CPU thread(s); ${HUGEPAGES_REQUIRED} required (2 MiB each)."
mkdir -p "$(dirname "$SYSCTL_CONF")"
TMP_CONF="$(mktemp)"
cat > "$TMP_CONF" <<CONF
# Seine CPU miner HugeTLB pages
# ${HUGEPAGES_PER_THREAD} x 2 MiB per CPU thread; allocation may depend on RAM at boot.
vm.nr_hugepages = ${HUGEPAGES_TARGET}
CONF
install -o root -g root -m 0644 "$TMP_CONF" "$SYSCTL_CONF"
rm -f "$TMP_CONF"
TMP_CONF=''
log "Persistent setting written to $SYSCTL_CONF"

current_total="$(huge_total)"
current_free="$(huge_free)"
available_kb="$(mem_avail)"

if (( current_free < HUGEPAGES_REQUIRED )); then
  log "Huge pages currently: total=${current_total}, free=${current_free}; need ${HUGEPAGES_REQUIRED} free."
  shortfall=$(( HUGEPAGES_REQUIRED - current_free ))
  need_kb=$(( shortfall * 2048 ))
  if (( available_kb < need_kb + 262144 )); then
    log "Warning: MemAvailable=${available_kb} kB is close to the ${need_kb} kB still needed for huge pages."
  fi

  log 'Dropping caches and compacting memory.'
  echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || log 'Warning: drop_caches was unavailable.'
  echo 1 > /proc/sys/vm/compact_memory 2>/dev/null || log 'Warning: memory compaction was unavailable.'
  sleep 1
  current_free="$(huge_free)"

  if (( current_free < HUGEPAGES_REQUIRED )); then
    if (( current_total < HUGEPAGES_TARGET )); then
      for attempt in 1 2 3; do
        log "Requesting ${HUGEPAGES_TARGET} huge pages (attempt ${attempt}/3)."
        if sysctl -w "vm.nr_hugepages=${HUGEPAGES_TARGET}"; then
          sleep 2
        else
          log 'Warning: sysctl could not set vm.nr_hugepages.'
        fi

        current_total="$(huge_total)"
        current_free="$(huge_free)"
        if (( current_free >= HUGEPAGES_REQUIRED )); then
          break
        fi

        if (( attempt < 3 )); then
          echo 1 > /proc/sys/vm/compact_memory 2>/dev/null || true
          sleep 2
        fi
      done
    else
      log "HugePages_Total=${current_total} already meets target ${HUGEPAGES_TARGET}, but only ${current_free} are free."
      log 'Another process may be using huge pages; increasing the pool will not help.'
    fi
  fi
else
  log "Enough huge pages are already free (${current_free}); leaving the active pool unchanged."
fi

current_total="$(huge_total)"
current_free="$(huge_free)"
available_kb="$(mem_avail)"
log "HugePages_Total=${current_total}; HugePages_Free=${current_free}; Hugepagesize=${page_size} kB; MemAvailable=${available_kb} kB."

if (( current_free < HUGEPAGES_REQUIRED )); then
  die "Only ${current_free} HugeTLB pages are free; ${CPU_THREADS} CPU thread(s) need at least ${HUGEPAGES_REQUIRED}. Not starting the miner. The sysctl setting remains saved; stop other huge-page users or reboot."
fi

# ------------------------------- relay -----------------------------------

EFFECTIVE_POOL="$POOL_URL"

if [[ "$MODE" == 'relay' ]]; then
  if [[ "$RELAY_CHECK" == 1 ]]; then
    log "Checking relay: ${RELAY_URL} -> ${RELAY_TARGET}"
    if ! python3 -u "$BRIDGE" --check \
        --relay "$RELAY_URL" \
        --target "$RELAY_TARGET" \
        --connect-timeout "$RELAY_CHECK_TIMEOUT" \
        --check-timeout "$RELAY_CHECK_TIMEOUT"; then
      die "Relay check failed. Verify RELAY_URL/RELAY_TARGET and that the relay host is awake."
    fi
  fi

  : >"$BRIDGE_LOG"
  log "Starting relay bridge: 127.0.0.1:${RELAY_LOCAL_PORT} -> ${RELAY_TARGET} via ${RELAY_URL}"
  python3 -u "$BRIDGE" \
    --listen "127.0.0.1:${RELAY_LOCAL_PORT}" \
    --relay "$RELAY_URL" \
    --target "$RELAY_TARGET" \
    >>"$BRIDGE_LOG" 2>&1 &
  BRIDGE_PID=$!

  ready=0
  for ((i = 0; i < 50; i++)); do
    if grep -q "listening on 127.0.0.1:${RELAY_LOCAL_PORT}" "$BRIDGE_LOG" 2>/dev/null; then
      ready=1
      break
    fi
    if ! kill -0 "$BRIDGE_PID" 2>/dev/null; then
      break
    fi
    sleep 0.2
  done

  if (( ready == 0 )); then
    log 'Relay bridge failed to start. Last log lines:'
    tail -n 20 "$BRIDGE_LOG" >&2 || true
    BRIDGE_PID=''
    die 'Relay bridge is not listening.'
  fi

  EFFECTIVE_POOL="stratum+tcp://127.0.0.1:${RELAY_LOCAL_PORT}"
fi

# ------------------------------- mining ----------------------------------

log 'HugeTLB check passed. Starting Seine.'
if [[ "$MODE" == 'relay' ]]; then
  log "Relay: ${RELAY_URL} -> ${RELAY_TARGET}"
  log "Local pool endpoint: ${EFFECTIVE_POOL}"
else
  log "Pool: ${EFFECTIVE_POOL}"
fi
log "Payout address: ${ADDRESS}"
log "Pool worker: ${POOL_WORKER}"
log "CPU threads: ${CPU_THREADS}; page mode: ${CPU_PAGE_MODE}"
[[ "$MODE" == 'relay' ]] && log "Bridge log: ${BRIDGE_LOG}"
log 'Press Ctrl+C to stop mining.'

MINER_ARGS=(
  --pool-url "$EFFECTIVE_POOL"
  --address "$ADDRESS"
  --threads "$CPU_THREADS"
  --cpu-page-mode "$CPU_PAGE_MODE"
)
if [[ -n "$POOL_WORKER" ]]; then
  MINER_ARGS+=(--pool-worker "$POOL_WORKER")
fi

log "Command: ${MINER} ${MINER_ARGS[*]}"

# Run in the foreground so the TUI and Ctrl+C work normally. The EXIT trap
# stops the background relay bridge when Seine exits.
"$MINER" "${MINER_ARGS[@]}"
