#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
#
# Set up the `xtensa-llvm` rustup toolchain for SOF / Xtensa Rust work.
#
# This is the scripted form of the manual workflow documented in
# SOFTODO.md (§Working today → Toolchain). It:
#
#   1. Verifies the local Xtensa LLVM build is reachable and writes a
#      bootstrap.toml entry pointing rustc's wrapper at it (only if the
#      file does not already configure the host target).
#   2. Builds `library` and `cargo` via ./x at stage 2 (skipped if
#      build/host/stage2/bin/{rustc,cargo} are already present and
#      --rebuild is not given).
#   3. Symlinks build/host/stage2-tools-bin/cargo into
#      build/host/stage2/bin/ so rustup can find it (idempotent).
#   4. Registers the result with rustup as the `xtensa-llvm` toolchain
#      (re-linked if --force is given or the link is stale).
#   5. Smoke-tests the toolchain by running `rustc --version` and
#      `cargo --version` through the rustup proxy.
#   6. Optionally prints the environment exports that downstream SOF
#      builds expect (SOF_RUST_TOOLCHAIN, SOF_RUST_XTENSA_TARGET).
#
# Usage:
#
#   src/etc/sof-setup-toolchain.sh \
#       [--llvm-build /path/to/llvm-project/build] \
#       [--toolchain-name xtensa-llvm] \
#       [--target-spec /path/to/xtensa-intel_ace30_adsp-zephyr-elf.json] \
#       [--rebuild] [--force] [--print-env] [--quiet]
#
# Defaults:
#   --llvm-build       \$LLVM_BUILD or \$HOME/work/llvm-project/build
#   --toolchain-name   xtensa-llvm
#   --target-spec      <rust-repo>/xtensa-intel_ace30_adsp-zephyr-elf.json
#
# Run from the root of the rust source checkout (the directory
# containing ./x and bootstrap.toml).

set -euo pipefail

# ----------------------------------------------------------------------
# Defaults & arg parsing
# ----------------------------------------------------------------------

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LLVM_BUILD="${LLVM_BUILD:-$HOME/work/llvm-project/build}"
TOOLCHAIN_NAME="xtensa-llvm"
TARGET_SPEC="${REPO_ROOT}/xtensa-intel_ace30_adsp-zephyr-elf.json"
REBUILD=0
FORCE=0
PRINT_ENV=0
QUIET=0

usage() {
    sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

while (( $# > 0 )); do
    case "$1" in
        --llvm-build)      LLVM_BUILD="$2"; shift 2 ;;
        --toolchain-name)  TOOLCHAIN_NAME="$2"; shift 2 ;;
        --target-spec)     TARGET_SPEC="$2"; shift 2 ;;
        --rebuild)         REBUILD=1; shift ;;
        --force)           FORCE=1; shift ;;
        --print-env)       PRINT_ENV=1; shift ;;
        --quiet|-q)        QUIET=1; shift ;;
        -h|--help)         usage 0 ;;
        *) echo "unknown option: $1" >&2; usage 1 ;;
    esac
done

log() { (( QUIET )) || printf '[sof-setup] %s\n' "$*" >&2; }
die() { printf '[sof-setup] error: %s\n' "$*" >&2; exit 1; }

# ----------------------------------------------------------------------
# Sanity checks
# ----------------------------------------------------------------------

[[ -x "${REPO_ROOT}/x" ]]            || die "no ./x in ${REPO_ROOT} - run from the rust source checkout"
[[ -f "${REPO_ROOT}/bootstrap.toml" || -f "${REPO_ROOT}/bootstrap.example.toml" ]] \
    || die "no bootstrap.toml(.example) in ${REPO_ROOT}"

LLVM_CONFIG="${LLVM_BUILD}/bin/llvm-config"
[[ -x "${LLVM_CONFIG}" ]] \
    || die "llvm-config not found at ${LLVM_CONFIG} (pass --llvm-build or set LLVM_BUILD)"

LLVM_VERSION="$("${LLVM_CONFIG}" --version)"
LLVM_TARGETS="$("${LLVM_CONFIG}" --targets-built)"
log "LLVM ${LLVM_VERSION} at ${LLVM_BUILD} (targets: ${LLVM_TARGETS})"
[[ " ${LLVM_TARGETS} " == *" Xtensa "* ]] \
    || die "Xtensa target missing from LLVM build at ${LLVM_BUILD}"

command -v rustup >/dev/null \
    || die "rustup not found on PATH (https://rustup.rs)"

[[ -f "${TARGET_SPEC}" ]] \
    || log "warning: target spec ${TARGET_SPEC} not found (downstream cross builds will fail)"

# ----------------------------------------------------------------------
# bootstrap.toml: ensure host target points at the local LLVM
# ----------------------------------------------------------------------

# Try several sources in order: any already-built stage rustc, the
# system rustc (via the rustup proxy with whatever default toolchain
# is active), or `rustup show host` as a last resort. Falling back is
# important because users running this script for the first time may
# have no default rustup toolchain set yet.
HOST_TRIPLE=""
for candidate in \
        "${REPO_ROOT}/build/host/stage2/bin/rustc" \
        "${REPO_ROOT}/build/host/stage1/bin/rustc" \
        "${REPO_ROOT}/build/host/stage0/bin/rustc"; do
    if [[ -x "${candidate}" ]]; then
        HOST_TRIPLE="$("${candidate}" --version --verbose 2>/dev/null | awk '/^host:/ {print $2}')"
        [[ -n "${HOST_TRIPLE}" ]] && break
    fi
done
if [[ -z "${HOST_TRIPLE}" ]]; then
    HOST_TRIPLE="$(rustc --version --verbose 2>/dev/null | awk '/^host:/ {print $2}' || true)"
fi
if [[ -z "${HOST_TRIPLE}" ]]; then
    # Final fallback: derive from `rustup show` (works even when no
    # default toolchain is set, since `host` is a property of rustup).
    HOST_TRIPLE="$(rustup show 2>/dev/null | awk -F': ' '/^Default host:/ {print $2; exit}')"
fi
[[ -n "${HOST_TRIPLE}" ]] || die "could not determine host triple - set RUSTUP_TOOLCHAIN or install a default rustup toolchain"
log "host triple: ${HOST_TRIPLE}"

BOOTSTRAP="${REPO_ROOT}/bootstrap.toml"
if [[ ! -f "${BOOTSTRAP}" ]]; then
    log "creating ${BOOTSTRAP}"
    cat > "${BOOTSTRAP}" <<EOF
# Auto-generated by src/etc/sof-setup-toolchain.sh
[llvm]
download-ci-llvm = false

[target.${HOST_TRIPLE}]
llvm-config = "${LLVM_CONFIG}"
EOF
else
    if grep -qE "^\\[target\\.${HOST_TRIPLE}\\]" "${BOOTSTRAP}"; then
        log "bootstrap.toml already configures [target.${HOST_TRIPLE}]"
    else
        log "appending [target.${HOST_TRIPLE}] llvm-config to bootstrap.toml"
        {
            echo
            echo "# Added by src/etc/sof-setup-toolchain.sh"
            echo "[target.${HOST_TRIPLE}]"
            echo "llvm-config = \"${LLVM_CONFIG}\""
        } >> "${BOOTSTRAP}"
    fi
    if ! grep -qE "^\\[llvm\\]" "${BOOTSTRAP}"; then
        log "appending [llvm] download-ci-llvm = false"
        {
            echo
            echo "# Added by src/etc/sof-setup-toolchain.sh"
            echo "[llvm]"
            echo "download-ci-llvm = false"
        } >> "${BOOTSTRAP}"
    fi
fi

# ----------------------------------------------------------------------
# Build stage2 library + cargo
# ----------------------------------------------------------------------

STAGE2="${REPO_ROOT}/build/host/stage2"
STAGE2_BIN="${STAGE2}/bin"
STAGE2_TOOLS="${REPO_ROOT}/build/host/stage2-tools-bin"

if (( REBUILD )) || [[ ! -x "${STAGE2_BIN}/rustc" ]]; then
    log "building stage2 library (./x build library)"
    (cd "${REPO_ROOT}" && ./x build library)
else
    log "stage2 rustc already present; skipping ./x build library (use --rebuild to force)"
fi

if (( REBUILD )) || [[ ! -x "${STAGE2_TOOLS}/cargo" ]]; then
    log "building stage2 cargo (./x build cargo)"
    (cd "${REPO_ROOT}" && ./x build cargo)
else
    log "stage2 cargo already present; skipping ./x build cargo (use --rebuild to force)"
fi

[[ -x "${STAGE2_BIN}/rustc" ]] || die "stage2 rustc missing after build"
[[ -x "${STAGE2_TOOLS}/cargo" ]] || die "stage2 cargo missing after build"

# ----------------------------------------------------------------------
# Cargo symlink
# ----------------------------------------------------------------------

CARGO_LINK="${STAGE2_BIN}/cargo"
if [[ -L "${CARGO_LINK}" ]]; then
    target="$(readlink "${CARGO_LINK}")"
    if [[ "${target}" != "${STAGE2_TOOLS}/cargo" ]]; then
        log "refreshing stale cargo symlink (was -> ${target})"
        ln -sfn "${STAGE2_TOOLS}/cargo" "${CARGO_LINK}"
    else
        log "cargo symlink already in place"
    fi
elif [[ -e "${CARGO_LINK}" ]]; then
    die "${CARGO_LINK} exists and is not a symlink; refusing to clobber"
else
    log "creating cargo symlink ${CARGO_LINK} -> ${STAGE2_TOOLS}/cargo"
    ln -s "${STAGE2_TOOLS}/cargo" "${CARGO_LINK}"
fi

# ----------------------------------------------------------------------
# Register with rustup
# ----------------------------------------------------------------------

LINKED_PATH=""
if rustup toolchain list 2>/dev/null | grep -q "^${TOOLCHAIN_NAME}\b"; then
    # `rustup which` returns the path *inside* the toolchain link
    # (e.g. ~/.rustup/toolchains/<name>/bin/rustc); follow symlinks so
    # we compare against the real stage2 dir for idempotency.
    raw="$(rustup which --toolchain "${TOOLCHAIN_NAME}" rustc 2>/dev/null || true)"
    if [[ -n "${raw}" ]]; then
        LINKED_PATH="$(dirname "$(readlink -f "${raw}")")"
    fi
fi
STAGE2_BIN_REAL="$(readlink -f "${STAGE2_BIN}")"

if [[ -z "${LINKED_PATH}" ]]; then
    log "linking rustup toolchain ${TOOLCHAIN_NAME} -> ${STAGE2}"
    rustup toolchain link "${TOOLCHAIN_NAME}" "${STAGE2}"
elif [[ "${LINKED_PATH}" != "${STAGE2_BIN_REAL}" ]] || (( FORCE )); then
    log "re-linking rustup toolchain ${TOOLCHAIN_NAME} (was at ${LINKED_PATH})"
    rustup toolchain uninstall "${TOOLCHAIN_NAME}" >/dev/null 2>&1 || true
    rustup toolchain link "${TOOLCHAIN_NAME}" "${STAGE2}"
else
    log "rustup toolchain ${TOOLCHAIN_NAME} already linked to ${STAGE2}"
fi

# ----------------------------------------------------------------------
# Smoke test
# ----------------------------------------------------------------------

log "smoke-testing toolchain"
RUSTC_VER="$(rustc "+${TOOLCHAIN_NAME}" --version)"
CARGO_VER="$(cargo "+${TOOLCHAIN_NAME}" --version)"
log "  rustc: ${RUSTC_VER}"
log "  cargo: ${CARGO_VER}"

if [[ -f "${TARGET_SPEC}" ]]; then
    log "verifying target spec is parseable by stage2 rustc"
    if ! rustc "+${TOOLCHAIN_NAME}" -Z unstable-options --target "${TARGET_SPEC}" \
            --print target-spec-json >/dev/null 2>&1; then
        log "  warning: rustc could not parse ${TARGET_SPEC}"
    else
        log "  ok"
    fi
fi

# ----------------------------------------------------------------------
# Done
# ----------------------------------------------------------------------

if (( PRINT_ENV )); then
    cat <<EOF
# Add to your shell rc to make SOF builds pick up this toolchain by default:
export SOF_RUST_TOOLCHAIN="${TOOLCHAIN_NAME}"
export SOF_RUST_XTENSA_TARGET="${TARGET_SPEC}"
EOF
fi

log "done. Use 'cargo +${TOOLCHAIN_NAME} ...' or set SOF_RUST_TOOLCHAIN=${TOOLCHAIN_NAME}."
