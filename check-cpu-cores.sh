#!/usr/bin/env bash
# =============================================================================
# check-cpu-cores.sh
#
# Per-core CPU stability test (self-checking workload) + frequency control.
#
# The test runs a tiny setuptools code path once per iteration on each logical
# CPU and checks that it finishes cleanly. A core that corrupts execution will
# crash the process (SIGSEGV / SIGABRT / GP fault) instead of printing "ok".
# This catches faults that tools like `stress` miss, because they never verify
# their own results.
#
# It runs serially, one core at a time, so the core can boost to its maximum
# clock. Parallel load would lower the boost and hide the fault.
#
# USAGE
#   ./check-cpu-cores.sh                    # test all online CPUs, 20 runs each
#   ./check-cpu-cores.sh -n 40              # more runs for confidence
#   ./check-cpu-cores.sh -c "8 9 10 11"     # only these CPUs
#   ./check-cpu-cores.sh cap 4500000 8 9 10 11   # cap those cores at 4.5 GHz
#   ./check-cpu-cores.sh cap 4500000              # cap every CPU
#   ./check-cpu-cores.sh restore            # back to stock max (all CPUs)
#   ./check-cpu-cores.sh restore 8 9 10 11  # restore only these
#   ./check-cpu-cores.sh status             # show limits / current clocks
#   ./check-cpu-cores.sh status 8 10 11     # ... for specific CPUs
#
# FREQUENCY CONTROL (Intel intel_pstate; values in kHz)
#   File: /sys/devices/system/cpu/cpuN/cpufreq/scaling_max_freq
#   4500000 = 4.5 GHz, 5500000 = 5.5 GHz, 6000000 = 6.0 GHz
#
#   read:    cat /sys/devices/system/cpu/cpu10/cpufreq/scaling_max_freq
#   cap:     echo 4500000 | sudo tee /sys/devices/system/cpu/cpu10/cpufreq/scaling_max_freq
#   restore: echo 6000000 | sudo tee /sys/devices/system/cpu/cpu10/cpufreq/scaling_max_freq
#   turbo off (blunt, affects all cores): echo 1 | sudo tee /sys/devices/system/cpu/intel_pstate/no_turbo
#   turbo on:                              echo 0 | sudo tee /sys/devices/system/cpu/intel_pstate/no_turbo
#
#   *** These settings are volatile and reset on every reboot. ***
#   See the persistence example at the bottom of this file.
#
# EXIT STATUS
#   0 = all tested cores clean, 1 = at least one failure, 2 = usage/setup error
# =============================================================================
set -u

DEFAULT_RUNS=20
PROBE=""
ERRFILE=""
export PYTHON="${PYTHON:-python3}"

cleanup() {
  [ -n "$PROBE" ] && rm -f "$PROBE"
  [ -n "$ERRFILE" ] && rm -f "$ERRFILE"
}
trap cleanup EXIT INT TERM

die() { echo "error: $*" >&2; exit 2; }

usage() {
  awk 'NR == 1 { next }
       /^# =+$/ { if (++n == 2) exit; next }
       { sub(/^# ?/, ""); print }' "$0"
  exit 0
}

ghz() { awk -v k="${1:-0}" 'BEGIN { printf "%.2f", k / 1000000 }'; }

cpu_dir() { echo "/sys/devices/system/cpu/cpu$1"; }
freq_file() { echo "$(cpu_dir "$1")/cpufreq/$2"; }

all_online_cpus() {
  local d n
  for d in /sys/devices/system/cpu/cpu[0-9]*; do
    [ -d "$d/cpufreq" ] || continue
    n=${d##*cpu}
    if [ -r "$d/online" ] && [ "$(cat "$d/online")" = "0" ]; then
      continue
    fi
    echo "$n"
  done | sort -n
}

resolve_cpus() {
  # $1 = user list (possibly empty) -> echoes a validated, sorted list.
  # Returns non-zero on bad input so callers can exit even though the list is
  # captured via command substitution (where exit only leaves the subshell).
  local list="$1" c
  [ -z "$list" ] && list=$(all_online_cpus)
  for c in $list; do
    [[ "$c" =~ ^[0-9]+$ ]] || { echo "error: invalid CPU number: $c" >&2; return 2; }
    [ -d "$(cpu_dir "$c")" ] || { echo "error: cpu$c does not exist" >&2; return 2; }
  done
  echo "$list" | tr ' ' '\n' | sed '/^$/d' | sort -n | tr '\n' ' '
  return 0
}

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "note: writing frequency limits needs root (sudo); you may be asked for a password."
  fi
}

set_max_freq() {
  # $1 = cpu, $2 = kHz
  local f
  f=$(freq_file "$1" scaling_max_freq)
  if [ "$(id -u)" -eq 0 ]; then
    printf '%s\n' "$2" > "$f" 2>/dev/null
  else
    printf '%s\n' "$2" | sudo tee "$f" >/dev/null
  fi
}

do_status() {
  local cpus list c core gov epp cur max min
  list=$(resolve_cpus "$1") || exit $?
  echo "profile=$(powerprofilesctl get 2>/dev/null || echo n/a)   no_turbo=$(cat /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null || echo n/a)"
  printf "%-4s %-5s %-7s %-7s %-7s %-6s %-8s %-12s\n" \
    cpu core online max cur hwmin governor epp
  for c in $list; do
    [ -r "$(cpu_dir "$c")/online" ] && online=$(cat "$(cpu_dir "$c")/online") || online=1
    core=$(cat "$(cpu_dir "$c")/topology/core_id" 2>/dev/null || echo -)
    max=$(cat "$(freq_file "$c" scaling_max_freq)" 2>/dev/null || echo 0)
    cur=$(cat "$(freq_file "$c" scaling_cur_freq)" 2>/dev/null || echo 0)
    min=$(cat "$(freq_file "$c" cpuinfo_min_freq)" 2>/dev/null || echo 0)
    gov=$(cat "$(freq_file "$c" scaling_governor)" 2>/dev/null || echo -)
    epp=$(cat "$(freq_file "$c" energy_performance_preference)" 2>/dev/null || echo -)
    printf "%-4s %-5s %-7s %-7s %-7s %-6s %-8s %-12s\n" \
      "$c" "$core" "$online" "$(ghz "$max")" "$(ghz "$cur")" "$(ghz "$min")" "$gov" "$epp"
  done
}

do_cap() {
  local khz="$1" cpus="$2" list c hwmin hwmax val note after fails=0
  list=$(resolve_cpus "$cpus") || exit $?
  need_root
  for c in $list; do
    hwmax=$(cat "$(freq_file "$c" cpuinfo_max_freq)" 2>/dev/null || echo 0)
    hwmin=$(cat "$(freq_file "$c" cpuinfo_min_freq)" 2>/dev/null || echo 0)
    val=$khz
    note=""
    if [ "$hwmax" -gt 0 ] && [ "$val" -gt "$hwmax" ]; then
      val=$hwmax; note=" (clamped to hw max)"
    fi
    if [ "$val" -lt "$hwmin" ]; then
      val=$hwmin; note=" (clamped to hw min)"
    fi
    if ! set_max_freq "$c" "$val"; then
      echo "cpu$c: FAILED to write max frequency" >&2
      fails=$((fails + 1))
      continue
    fi
    after=$(cat "$(freq_file "$c" scaling_max_freq)")
    echo "cpu$c: max = $after kHz ($(ghz "$after") GHz)$note"
  done
  echo
  echo "note: scaling_max_freq is volatile and resets on reboot."
  [ "$fails" -eq 0 ] || exit 2
}

do_restore() {
  local cpus="$1" list c hwmax after fails=0
  list=$(resolve_cpus "$cpus") || exit $?
  need_root
  for c in $list; do
    hwmax=$(cat "$(freq_file "$c" cpuinfo_max_freq)" 2>/dev/null || echo 0)
    if [ "$hwmax" -eq 0 ]; then
      echo "cpu$c: cannot read cpuinfo_max_freq" >&2
      fails=$((fails + 1))
      continue
    fi
    if ! set_max_freq "$c" "$hwmax"; then
      echo "cpu$c: FAILED to restore" >&2
      fails=$((fails + 1))
      continue
    fi
    after=$(cat "$(freq_file "$c" scaling_max_freq)")
    echo "cpu$c: max = $after kHz ($(ghz "$after") GHz)"
  done
  [ "$fails" -eq 0 ] || exit 2
}

make_probe() {
  PROBE=$(mktemp "${TMPDIR:-/tmp}/cpucheck.XXXXXX.py") || die "mktemp failed"
  cat > "$PROBE" <<'PY'
from setuptools.dist import Distribution
from setuptools._distutils.command.install import install as dist_install
d = Distribution({'name': 'x', 'version': '1'})
cmd = dist_install(d); cmd.finalize_options(); print('ok')
PY
}

# Run the probe once, unpinned, before testing any core. If it cannot even run
# here, every core would report 100% failure and that would look like broken
# hardware. Report the real Python error and exit instead.
probe_selftest() {
  local rc
  ERRFILE=$(mktemp "${TMPDIR:-/tmp}/cpucheck.err.XXXXXX") || die "mktemp failed"
  sh -c '"$1" "$2" 2>"$3"; exit $?' _ "$PYTHON" "$PROBE" "$ERRFILE" \
    >/dev/null 2>/dev/null
  rc=$?
  [ "$rc" -eq 0 ] && return 0

  if [ "$rc" -lt 128 ]; then
    # Ordinary non-zero exit: Python/taskset/config error, not a CPU crash.
    echo "error: the test probe does not run on this Python ($PYTHON)." >&2
    echo "       This is a setup problem, not a CPU fault." >&2
    sed 's/^/       /' "$ERRFILE" >&2
    echo >&2
    echo "       Try:  $PYTHON -c 'import setuptools, sys; print(sys.version)'" >&2
    echo "       and:  $PYTHON -c 'from setuptools._distutils.command.install import install'" >&2
    echo "       On Debian/Ubuntu:  sudo apt install python3-setuptools" >&2
    exit 2
  fi

  # Killed by a signal: could be a genuinely faulty core. Continue so the
  # per-core results identify which CPU it is.
  echo "warning: the probe crashed unpinned (exit $rc, killed by a signal)." >&2
  echo "         Continuing; the per-core results below show which CPU is faulty." >&2
  echo >&2
}

run_tests() {
  local runs="$1" cpus="$2"
  local list c i f core maxg rate bad="" total_fail=0 total_runs=0 started=$SECONDS
  local soft=0 rc=0 tested=0

  command -v taskset >/dev/null 2>&1 || die "taskset not found (util-linux)"
  command -v "$PYTHON" >/dev/null 2>&1 || die "python not found: $PYTHON"
  "$PYTHON" -c 'import setuptools' >/dev/null 2>&1 \
    || die "$PYTHON cannot import setuptools (install python-setuptools)"

  ulimit -c 0 2>/dev/null || true
  make_probe
  probe_selftest
  list=$(resolve_cpus "$cpus") || exit $?

  echo "Python: $PYTHON   runs per CPU: $runs"
  echo "Note: core max clocks are read live; a capped core shows its cap."
  echo
  printf "%-4s %-5s %-7s %-6s %-6s %-8s %s\n" \
    cpu core maxGHz runs fail rate result
  printf "%-4s %-5s %-7s %-6s %-6s %-8s %s\n" \
    ---- ----- ------- ------ ------ -------- ------

  for c in $list; do
    if [ -r "$(cpu_dir "$c")/online" ] && [ "$(cat "$(cpu_dir "$c")/online")" = "0" ]; then
      printf "%-4s %-5s %-7s %-6s %-6s %-8s %s\n" "$c" - - "$runs" - - "SKIP (offline)"
      continue
    fi
    f=0
    soft=0
    for ((i = 0; i < runs; i++)); do
      # A signal (rc >= 128) means the core crashed: hardware evidence.
      # An ordinary non-zero exit (rc 1..127) is a Python/taskset error and
      # must not be counted as a CPU fault. The inner shell captures the real
      # error while the outer one swallows bash's "Segmentation fault" noise.
      sh -c 'taskset -c "$1" "$2" "$3" 2>"$4"; exit $?' _ \
        "$c" "$PYTHON" "$PROBE" "$ERRFILE" >/dev/null 2>/dev/null
      rc=$?
      if [ "$rc" -eq 0 ]; then
        continue
      elif [ "$rc" -ge 128 ]; then
        f=$((f + 1))
      else
        soft=$((soft + 1))
      fi
    done
    if [ "$soft" -gt 0 ]; then
      echo
      echo "error: cpu$c had $soft/$runs runs exit with an error, not a crash." >&2
      echo "       This is a software/setup problem, not a CPU fault. First error:" >&2
      sed 's/^/       /' "$ERRFILE" >&2
      echo >&2
      echo "       Run without taskset to see it directly:" >&2
      echo "         $PYTHON $PROBE" >&2
      exit 2
    fi
    tested=$((tested + 1))
    core=$(cat "$(cpu_dir "$c")/topology/core_id" 2>/dev/null || echo -)
    maxg=$(ghz "$(cat "$(freq_file "$c" scaling_max_freq)" 2>/dev/null || echo 0)")
    rate=$(awk -v f="$f" -v n="$runs" 'BEGIN { printf "%.0f%%", 100 * f / n }')
    total_fail=$((total_fail + f))
    total_runs=$((total_runs + runs))
    if [ "$f" -eq 0 ]; then
      printf "%-4s %-5s %-7s %-6s %-6s %-8s %s\n" "$c" "$core" "$maxg" "$runs" "$f" "$rate" "OK"
    else
      printf "%-4s %-5s %-7s %-6s %-6s %-8s %s\n" "$c" "$core" "$maxg" "$runs" "$f" "$rate" "FAIL"
      bad="$bad cpu$c($f/$runs)"
    fi
  done

  echo
  echo "Tested $total_runs runs in $((SECONDS - started))s. Failures: $total_fail."
  if [ "$total_fail" -eq 0 ]; then
    echo "=> All tested CPUs clean."
    exit 0
  fi

  echo "=> Failing CPUs:$bad"
  if [ "$tested" -gt 4 ] && [ "$total_fail" -eq "$total_runs" ]; then
    echo "   NOTE: every run failed. That is almost always a broken probe/setup,"
    echo "   not hardware. Check: $PYTHON $PROBE"
    echo
  fi
  echo "   Same code, same binary, only the pinned CPU changes: that is a hardware"
  echo "   fault, not a software bug. Try to confirm with a frequency cap:"
  echo
  echo "     ./check-cpu-cores.sh cap 4500000 8 9 10 11"
  echo "     ./check-cpu-cores.sh -c \"8 9 10 11\" -n 40"
  echo "     ./check-cpu-cores.sh restore 8 9 10 11"
  echo
  echo "   If it still fails at 4.5 GHz, the silicon is degraded enough to need"
  echo "   replacement (RMA); if it passes, the cap is a usable workaround."
  exit 1
}

CMD=test
RUNS=$DEFAULT_RUNS
CPU_LIST=""
CAP_KHZ=""

case "${1:-}" in
  cap)
    CMD=cap
    shift
    [ $# -ge 1 ] || die "cap: missing frequency in kHz (e.g. 4500000)"
    CAP_KHZ=$1
    shift
    [[ "$CAP_KHZ" =~ ^[0-9]+$ ]] || die "cap: frequency must be an integer in kHz"
    CPU_LIST="$*"
    set --
    ;;
  restore) CMD=restore; shift; CPU_LIST="$*"; set -- ;;
  status)  CMD=status;  shift; CPU_LIST="$*"; set -- ;;
  test)    shift ;;
  -h|--help) usage ;;
esac

while [ $# -gt 0 ]; do
  case "$1" in
    -n|--runs)
      [ $# -ge 2 ] || die "-n needs a value"
      RUNS=$2; shift 2 ;;
    -c|--cpus)
      [ $# -ge 2 ] || die "-c needs a value"
      CPU_LIST=$2; shift 2 ;;
    -h|--help) usage ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ "$RUNS" =~ ^[0-9]+$ ]] && [ "$RUNS" -gt 0 ] || die "runs must be a positive integer"

case "$CMD" in
  cap) do_cap "$CAP_KHZ" "$CPU_LIST" ;;
  restore) do_restore "$CPU_LIST" ;;
  status) do_status "$CPU_LIST" ;;
  test) run_tests "$RUNS" "$CPU_LIST" ;;
esac

# =============================================================================
# MAKING A CAP PERSISTENT (optional; caps reset on every reboot)
#
# /etc/systemd/system/cpu-freq-cap.service
# -----------------------------------------------------------------------------
# [Unit]
# Description=Cap max frequency on selected CPUs
# After=multi-user.target
#
# [Service]
# Type=oneshot
# ExecStart=/bin/sh -c 'for c in 8 9 10 11; do echo 4500000 > /sys/devices/system/cpu/cpu$c/cpufreq/scaling_max_freq; done'
# RemainAfterExit=yes
#
# [Install]
# WantedBy=multi-user.target
# -----------------------------------------------------------------------------
# Install with:
#   sudo systemctl daemon-reload
#   sudo systemctl enable --now cpu-freq-cap.service
# Undo with:
#   sudo systemctl disable --now cpu-freq-cap.service
# =============================================================================
