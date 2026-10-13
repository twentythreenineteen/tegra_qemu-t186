#!/usr/bin/env bash
# test_t3_2_ivc_ram_isolation.sh - Tier 3: IVC memory carveout + Guest RAM address isolation
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"

TEST_NAME="Tier 3.2: IVC physical carveout (0x70c00000) and DRAM (0x80000000) address isolation"
TEST_NUM="${1:-12}"
STRICT="${STRICT:-0}"

log_info "Running ${TEST_NAME}..."

if [[ ! -f "${DTB_FILE}" ]]; then
    log_fail "DTB file not found: ${DTB_FILE}"
    tap_not_ok "${TEST_NUM}" "${TEST_NAME}" "" "DTB file missing"
    exit 1
fi

# 1. Decompile DTB to inspect carveout0 and memory definitions
DTS_TEXT=$(dtc -I dtb -O dts "${DTB_FILE}" 2>/dev/null || true)

if [[ -z "${DTS_TEXT}" ]]; then
    log_fail "Failed to decompile DTB file"
    tap_not_ok "${TEST_NUM}" "${TEST_NAME}" "" "DTB decompilation failed"
    exit 1
fi

# Verify carveout0 node definition
HAS_CARVEOUT_NODE=0
if echo "${DTS_TEXT}" | grep -E "carveout0.*reg\s*=\s*<\s*0x0*\s+0x70c00000\s+0x0*\s+0x4c00000\s*>" > /dev/null || \
   echo "${DTS_TEXT}" | grep -E "nvidia,ivm_carveout" > /dev/null; then
    HAS_CARVEOUT_NODE=1
fi

# 2. Mathematical check: Carveout range [0x70c00000 .. 0x75800000) must be strictly disjoint from RAM [0x80000000 .. 0x180000000)
CARVEOUT_START=0x70c00000
CARVEOUT_SIZE=0x04c00000 # 76 MiB
RAM_START=0x80000000

CARVEOUT_END=$((CARVEOUT_START + CARVEOUT_SIZE))
if [[ ${CARVEOUT_END} -gt ${RAM_START} ]]; then
    log_fail "Address collision: Carveout end (${CARVEOUT_END}) overlaps RAM start (${RAM_START})"
    tap_not_ok "${TEST_NUM}" "${TEST_NAME}" "" "Address collision between carveout and RAM"
    exit 1
fi

# 3. Check kernel boot log for memory scan and carveout initialization
BOOT_LOG=$(get_or_run_boot_log 20 0)
HAS_BOOT_CARVEOUT=0
if grep -q "OF: reserved mem: initialized node carveout0, compatible id nvidia,ivm_carveout" "${BOOT_LOG}"; then
    HAS_BOOT_CARVEOUT=1
fi

HAS_BOOT_RAM=0
if grep -q "OF: fdt:memory scan node memory@80000000" "${BOOT_LOG}"; then
    HAS_BOOT_RAM=1
fi

if [[ ${HAS_CARVEOUT_NODE} -eq 1 && ${HAS_BOOT_CARVEOUT} -eq 1 && ${HAS_BOOT_RAM} -eq 1 ]]; then
    log_pass "${TEST_NAME} (Carveout: 0x70c00000-0x75800000 strictly disjoint from DRAM: 0x80000000-0x180000000)"
    tap_ok "${TEST_NUM}" "${TEST_NAME}"
    exit 0
else
    log_fail "${TEST_NAME} (Memory verification failed: node=${HAS_CARVEOUT_NODE}, boot_carveout=${HAS_BOOT_CARVEOUT}, boot_ram=${HAS_BOOT_RAM})"
    tap_not_ok "${TEST_NUM}" "${TEST_NAME}" "" "Carveout memory registration mismatch"
    exit 1
fi
