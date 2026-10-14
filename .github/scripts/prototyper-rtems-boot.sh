#!/usr/bin/env bash
#
# Boot RTEMS in S-mode (RISCV_USE_S_MODE=True) through RustSBI Prototyper in QEMU.
# Target is qemu-virt64 with rv64imafdc BSP and Sstc timer extension.
# RustSBI replaces QEMU's bundled OpenSBI as the M-mode layer.
# In S-mode with Sstc (rv64,sstc=true), RTEMS clock driver directly programs stimecmp.
# Official BSP_RESET_BOARD_AT_EXIT=0 leaves the guest idle after clean shutdown.
# A run passes when the RustSBI banner, RTEMS ticker startup and completion markers
# all appear cleanly without fatal errors, panics, or unhandled exceptions.
#
# RTEMS and RSB are pinned commits whose build products are cached under .cache/rtems;
# RustSBI is rebuilt every run from the local checkout under test.

set -euo pipefail

readonly RTEMS_VERSION="7"
readonly RTEMS_COMMIT="af4616741c42875970d74a7326db106ffe92be7e"
readonly RSB_COMMIT="74fffa09a3df68b7e6cacabbde243ea7828edb34"

readonly RUSTSBI_MARKER='Hello RustSBI!'
readonly TEST_START_MARKER='*** BEGIN OF TEST CLOCK TICK ***'
readonly SUCCESS_MARKER='*** END OF TEST CLOCK TICK ***'

readonly BOOT_FAILURE_PATTERN='panicked|FAILED|FATAL|Fatal exception|Unhandled exception|Kernel panic|not syncing|System shutdown scheduled due to RustSBI panic'

readonly REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"

readonly CACHE_DIR="${RTEMS_CACHE_DIR:-${REPO_ROOT}/.cache/rtems}"
readonly DOWNLOADS_DIR="${CACHE_DIR}/downloads"
readonly PREFIX="${RTEMS_PREFIX:-${CACHE_DIR}/opt/rtems/${RTEMS_VERSION}}"
readonly RTEMS_SRC="${CACHE_DIR}/rtems-src"
readonly RSB_SRC="${CACHE_DIR}/rsb"
readonly LOG_DIR="${QEMU_LOG_DIR:-${REPO_ROOT}/qemu-logs}"
readonly LOG_NAME="prototyper-rtems.log"

readonly QEMU="${RTEMS_QEMU:-qemu-system-riscv64}"
readonly CPU="${RTEMS_CPU:-rv64,sstc=true}"
readonly MEMORY_MB="${RTEMS_MEMORY_MB:-256}"
readonly BOOT_TIMEOUT_SECS="${RTEMS_BOOT_TIMEOUT_SECS:-180}"
readonly SETTLE_SECS="${RTEMS_SETTLE_SECS:-5}"
readonly JOBS="${RTEMS_JOBS:-4}"

abspath() {
  if realpath -m "" >/dev/null 2>&1; then
    realpath -m "$1"
  else
    case "$1" in
      /*) printf '%s\n' "$1" ;;
      *) printf '%s\n' "$REPO_ROOT/$1" ;;
    esac
  fi
}

readonly CACHE_DIR_ABS="$(abspath "$CACHE_DIR")"
readonly DOWNLOADS_DIR_ABS="$(abspath "$DOWNLOADS_DIR")"
readonly PREFIX_ABS="$(abspath "$PREFIX")"
readonly RTEMS_SRC_ABS="$(abspath "$RTEMS_SRC")"
readonly RSB_SRC_ABS="$(abspath "$RSB_SRC")"
readonly LOG_DIR_ABS="$(abspath "$LOG_DIR")"
readonly LOG_FILE_ABS="${LOG_DIR_ABS}/${LOG_NAME}"
readonly RUSTSBI_ABS="$(abspath "${RTEMS_RUSTSBI:-${CARGO_TARGET_DIR:-${REPO_ROOT}/target}/riscv64gc-unknown-none-elf/release/rustsbi-prototyper-dynamic.elf}")"

readonly TICKER_ELF_ABS="${RTEMS_SRC_ABS}/build/riscv/rv64imafdc_s_mode/testsuites/samples/ticker.exe"

QEMU_PID=""
TERMINATED_BY_SCRIPT=0
LAST_QEMU_EXIT=0

reap_qemu() {
  local target_pid="${1:-$QEMU_PID}"
  if [[ -n "$target_pid" ]]; then
    local rc=0
    wait "$target_pid" 2>/dev/null || rc=$?
    LAST_QEMU_EXIT=$rc
    QEMU_PID=""
  fi
}

stop_qemu() {
  local target_pid="$QEMU_PID"
  if [[ -n "$target_pid" ]] && kill -0 "$target_pid" 2>/dev/null; then
    if kill "$target_pid" 2>/dev/null; then
      TERMINATED_BY_SCRIPT=1
    fi
    reap_qemu "$target_pid"
  elif [[ -n "$target_pid" ]]; then
    reap_qemu "$target_pid"
  fi
}

on_signal() {
  stop_qemu
  exit 130
}

trap 'on_signal' INT TERM
trap stop_qemu EXIT

download_asset() {
  local url="$1"
  local dest="$2"

  mkdir -p "$(dirname "$dest")"

  if [[ -s "$dest" ]]; then
    if [[ "$dest" == *.tar.* || "$dest" == *.tar ]]; then
      if tar -tf "$dest" >/dev/null 2>&1; then
        return 0
      fi
      echo "Existing archive $dest is corrupted, re-downloading..."
      rm -f "$dest"
    else
      return 0
    fi
  fi

  local temp
  temp="$(mktemp "${dest}.part.XXXXXX")"
  echo "Downloading $url -> $dest"
  if ! curl --http1.1 -fL --connect-timeout 15 -m 900 --retry 3 -o "$temp" "$url"; then
    rm -f "$temp"
    echo "Error: Failed to download $url" >&2
    return 1
  fi

  if [[ "$dest" == *.tar.* || "$dest" == *.tar || "$dest" == *.tgz ]]; then
    if ! tar -tf "$temp" >/dev/null 2>&1; then
      rm -f "$temp"
      echo "Error: Downloaded archive $temp failed integrity check" >&2
      return 1
    fi
  fi

  mv -f "$temp" "$dest"
}

build_rsb_toolchain() {
  local gcc="${PREFIX_ABS}/bin/riscv-rtems${RTEMS_VERSION}-gcc"
  if [[ -x "$gcc" ]]; then
    echo "Toolchain already installed at $gcc"
    return 0
  fi

  echo "Building RTEMS ${RTEMS_VERSION} RISC-V toolchain via RSB (jobs=${JOBS})..."
  local rsb_tar="${DOWNLOADS_DIR_ABS}/rsb-${RSB_COMMIT}.tar.gz"
  download_asset \
    "https://gitlab.rtems.org/api/v4/projects/rtems%2Ftools%2Frtems-source-builder/repository/archive.tar.gz?sha=${RSB_COMMIT}" \
    "$rsb_tar"

  if [[ ! -d "${RSB_SRC_ABS}/rtems" ]]; then
    mkdir -p "$RSB_SRC_ABS"
    tar -xzf "$rsb_tar" -C "$RSB_SRC_ABS" --strip-components=1
  fi

  (
    cd "${RSB_SRC_ABS}/rtems"
    export GIT_CEILING_DIRECTORIES="$CACHE_DIR_ABS"
    ../source-builder/sb-set-builder \
      --jobs="$JOBS" \
      --prefix="$PREFIX_ABS" \
      --without-release-url \
      --url "https://ftp.gnu.org/gnu/binutils,https://ftp.gnu.org/gnu/gcc/gcc-15.2.0,https://ftp.gnu.org/gnu/gdb" \
      "${RTEMS_VERSION}/rtems-riscv"
  )

  test -x "$gcc" || {
    echo "Error: Failed to build $gcc" >&2
    return 1
  }
}

build_rtems_sample() {
  export PATH="${PREFIX_ABS}/bin:${PATH}"

  local rtems_tar="${DOWNLOADS_DIR_ABS}/rtems-${RTEMS_COMMIT}.tar.gz"
  download_asset \
    "https://codeload.github.com/RTEMS/rtems/tar.gz/${RTEMS_COMMIT}" \
    "$rtems_tar"

  if [[ ! -f "${RTEMS_SRC_ABS}/waf" ]]; then
    mkdir -p "$RTEMS_SRC_ABS"
    tar -xzf "$rtems_tar" -C "$RTEMS_SRC_ABS" --strip-components=1
  fi

  (
    cd "$RTEMS_SRC_ABS"
    export GIT_CEILING_DIRECTORIES="$(dirname "$CACHE_DIR_ABS")"

    cat > VERSION <<EOF
[version]
revision = ${RTEMS_VERSION}.0.0-${RTEMS_COMMIT}
EOF

    cat > config.ini <<EOF
[riscv/rv64imafdc_s_mode]
INHERIT = rv64imafdc
RISCV_RAM_REGION_BEGIN = 0x84000000
RISCV_RAM_REGION_SIZE = 0x03000000
RISCV_USE_S_MODE = True
BUILD_SAMPLES = True
BSP_RESET_BOARD_AT_EXIT = 0
BSP_PRESS_KEY_FOR_RESET = 0
EOF

    echo "Configuring RTEMS BSP..."
    ./waf configure --prefix="$PREFIX_ABS"
    echo "Compiling RTEMS ticker sample (jobs=${JOBS})..."
    ./waf -j"$JOBS"
  )

  test -f "$TICKER_ELF_ABS" || {
    echo "Error: Failed to build ticker sample at $TICKER_ELF_ABS" >&2
    return 1
  }
}

build_rustsbi() {
  echo "Building RustSBI Prototyper (dynamic mode) from current tree..."
  (
    cd "$REPO_ROOT"
    CARGO_BUILD_JOBS="$JOBS" cargo prototyper build dynamic
  )
  test -s "$RUSTSBI_ABS" || {
    echo "Error: Missing $RUSTSBI_ABS" >&2
    return 1
  }
}

run_boot_test() {
  mkdir -p "$LOG_DIR_ABS"
  : > "$LOG_FILE_ABS"

  if ! command -v "$QEMU" >/dev/null 2>&1; then
    echo "Error: QEMU binary '$QEMU' not found or not executable" >&2
    return 1
  fi

  echo "Starting QEMU verification..."
  echo "  QEMU: $QEMU"
  echo "  CPU: $CPU"
  echo "  BIOS (RustSBI): $RUSTSBI_ABS"
  echo "  Kernel (RTEMS): $TICKER_ELF_ABS"
  echo "  Log: $LOG_FILE_ABS"

  "$QEMU" \
    -machine virt \
    -cpu "$CPU" \
    -m "${MEMORY_MB}M" \
    -smp 1 \
    -display none \
    -serial stdio \
    -monitor none \
    -bios "$RUSTSBI_ABS" \
    -kernel "$TICKER_ELF_ABS" \
    </dev/null >"$LOG_FILE_ABS" 2>&1 &
  QEMU_PID=$!

  local start_time
  start_time=$(date +%s)
  TERMINATED_BY_SCRIPT=0
  LAST_QEMU_EXIT=0

  while true; do
    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
      reap_qemu "$QEMU_PID"
      break
    fi

    if [[ -s "$LOG_FILE_ABS" ]]; then
      if grep -E -q "$BOOT_FAILURE_PATTERN" "$LOG_FILE_ABS"; then
        echo "Detected boot failure pattern in log!" >&2
        stop_qemu
        return 1
      fi

      if grep -F -q "$SUCCESS_MARKER" "$LOG_FILE_ABS"; then
        echo "Detected success marker! Settling for ${SETTLE_SECS}s to catch late exits or faults..."
        local settle_end
        settle_end=$(( $(date +%s) + SETTLE_SECS ))
        while (( $(date +%s) < settle_end )); do
          if ! kill -0 "$QEMU_PID" 2>/dev/null; then
            reap_qemu "$QEMU_PID"
            echo "QEMU exited naturally during settle with code: $LAST_QEMU_EXIT"
            break
          fi
          if grep -E -q "$BOOT_FAILURE_PATTERN" "$LOG_FILE_ABS"; then
            echo "Detected late failure pattern during settle!" >&2
            stop_qemu
            return 1
          fi
          sleep 0.5
        done

        if [[ -n "$QEMU_PID" ]]; then
          echo "QEMU still running after settle period; stopping via SIGTERM..."
          stop_qemu
        fi

        break
      fi
    fi

    local current_time
    current_time=$(date +%s)
    if (( current_time - start_time >= BOOT_TIMEOUT_SECS )); then
      # Recheck success marker on timeout boundary (per PR #322 review)
      if [[ -s "$LOG_FILE_ABS" ]] && grep -F -q "$SUCCESS_MARKER" "$LOG_FILE_ABS" && ! grep -E -q "$BOOT_FAILURE_PATTERN" "$LOG_FILE_ABS"; then
        echo "Success marker observed at timeout boundary; stopping QEMU..."
        stop_qemu
        break
      fi
      echo "Timeout waiting for RTEMS ticker boot (${BOOT_TIMEOUT_SECS}s)" >&2
      stop_qemu
      return 1
    fi

    sleep 1
  done

  # Shared post-loop validation for all paths (settle finish, natural exit, timeout boundary)
  if [[ -n "$QEMU_PID" ]]; then
    stop_qemu
  fi

  echo "Verifying log results..."
  if grep -E -q "$BOOT_FAILURE_PATTERN" "$LOG_FILE_ABS"; then
    echo "FAILED: Log contains forbidden failure pattern" >&2
    return 1
  fi

  if (( TERMINATED_BY_SCRIPT == 1 )); then
    if [[ $LAST_QEMU_EXIT -ne 0 && $LAST_QEMU_EXIT -ne 143 ]]; then
      echo "Error: QEMU terminated with unexpected exit code $LAST_QEMU_EXIT (expected 0 or 143 on SIGTERM)" >&2
      return 1
    fi
  else
    if [[ $LAST_QEMU_EXIT -ne 0 ]]; then
      echo "Error: QEMU exited naturally with non-zero exit code $LAST_QEMU_EXIT" >&2
      return 1
    fi
  fi

  if ! grep -F -q "$RUSTSBI_MARKER" "$LOG_FILE_ABS"; then
    echo "FAILED: Log missing RustSBI marker: $RUSTSBI_MARKER" >&2
    return 1
  fi

  if ! grep -F -q "$TEST_START_MARKER" "$LOG_FILE_ABS"; then
    echo "FAILED: Log missing ticker start marker: $TEST_START_MARKER" >&2
    return 1
  fi

  if ! grep -F -q "$SUCCESS_MARKER" "$LOG_FILE_ABS"; then
    echo "FAILED: Log missing ticker success marker: $SUCCESS_MARKER" >&2
    return 1
  fi

  # Count task time reports, not IRQs: the sample also prints each task's
  # initial timestamp before its first timer-driven wakeup.
  local tick_count
  tick_count=$(grep -c -E "TA[123]  -" "$LOG_FILE_ABS" || true)
  if (( tick_count < 5 )); then
    echo "FAILED: Expected multiple ticker wakeups, found only $tick_count" >&2
    return 1
  fi

  echo "SUCCESS: RustSBI booted RTEMS S-mode ticker cleanly with $tick_count task time reports verified."
}

check_cached_assets() {
  echo "Checking cached RTEMS assets..."
  local gcc="${PREFIX_ABS}/bin/riscv-rtems${RTEMS_VERSION}-gcc"
  if [[ -f "$gcc" ]]; then
    if ! "$gcc" --version >/dev/null 2>&1; then
      echo "Warning: Cached GCC binary at $gcc failed execution check, purging prefix and build..." >&2
      rm -rf "$PREFIX_ABS"
      rm -rf "${RTEMS_SRC_ABS}/build" "${RTEMS_SRC_ABS}/config.ini"
    else
      echo "Cached RTEMS toolchain verified: $($gcc --version | head -n 1)"
    fi
  else
    echo "No cached toolchain found at $gcc (cold build will run)"
  fi

  if [[ -d "$DOWNLOADS_DIR_ABS" ]]; then
    for arc in "${DOWNLOADS_DIR_ABS}"/*.tar.*; do
      if [[ -f "$arc" ]]; then
        if ! tar -tf "$arc" >/dev/null 2>&1; then
          echo "Warning: Cached archive $arc failed integrity check, removing..." >&2
          rm -f "$arc"
        else
          echo "Cached archive verified: $(basename "$arc")"
        fi
      fi
    done
  fi

  if [[ -f "$TICKER_ELF_ABS" ]]; then
    if ! head -c 4 "$TICKER_ELF_ABS" | grep -q $'\x7fELF'; then
      echo "Warning: Cached ticker binary $TICKER_ELF_ABS is not a valid ELF, purging build..." >&2
      rm -rf "${RTEMS_SRC_ABS}/build"
    else
      echo "Cached RTEMS ticker sample verified: $(basename "$TICKER_ELF_ABS")"
    fi
  fi
  return 0
}

main() {
  local action="${1:-boot}"
  case "$action" in
    check-cache)
      check_cached_assets
      ;;
    boot)
      build_rustsbi
      build_rsb_toolchain
      build_rtems_sample
      run_boot_test
      ;;
    *)
      echo "Usage: $0 [boot|check-cache]" >&2
      exit 2
      ;;
  esac
}

main "$@"
