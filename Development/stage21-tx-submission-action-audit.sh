#!/bin/bash
set -euo pipefail

REPO="shammu2bd/Realtek-WiFi-Native-macOS"
PROJECT="${RTL88_PROJECT:-$HOME/Downloads/RTL88WiFi-1.0.11-WCL-stage14-generic-skywalk-segment-abi}"
OUT="$PROJECT/output.log"
TMP="$(mktemp -d 2>/dev/null || mktemp -d -t rtl88-stage21)"
trap 'rm -rf "$TMP"' EXIT

if [ ! -d "$PROJECT" ]; then
    echo "ERROR: project directory not found: $PROJECT" >&2
    exit 2
fi

HDR="$PROJECT/driver/RTL88WiFi/MacKernelSDK/Headers/IOKit/skywalk"
BUILD="$PROJECT/build"
if [ ! -d "$HDR" ]; then
    echo "ERROR: bundled Skywalk header directory not found: $HDR" >&2
    exit 3
fi

{
    echo "RTL88WiFi Stage 21 — TX submission action call-site audit"
    echo "DATE: $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo "HOST: $(sw_vers -productVersion 2>/dev/null || echo unknown) / $(sw_vers -buildVersion 2>/dev/null || echo unknown)"
    echo "ARCH: $(uname -m)"
    echo "PROJECT: $PROJECT"
    echo

    echo "========== EXACT BUNDLED ACTION TYPEDEFS =========="
    for entry in \
        "IOSkywalkTxSubmissionQueue.h:IOSkywalkQueryFreeSpaceHandler|IOSkywalkTxSubmissionQueueAction" \
        "IOSkywalkTxCompletionQueue.h:IOSkywalkTxCompletionQueueAction" \
        "IOSkywalkRxSubmissionQueue.h:IOSkywalkRxSubmissionQueueAction" \
        "IOSkywalkRxCompletionQueue.h:IOSkywalkRxCompletionQueueAction"
    do
        name="${entry%%:*}"
        pattern="${entry#*:}"
        file="$HDR/$name"
        echo "--- $name ---"
        grep -nE "$pattern" "$file" || true
    done
    echo

    echo "========== LOCATE 24H32 TX SUBMISSION QUEUE METHODS =========="
    : > "$TMP/methods"
    if [ -d "$BUILD" ]; then
        find "$BUILD" -type f \
            \( -name '*IOSkywalkTxSubmissionQueue*legacyDequeue*.asm.txt' \
            -o -name '*IOSkywalkTxSubmissionQueue*listDequeue*.asm.txt' \
            -o -name '*IOSkywalkTxSubmissionQueue*checkForWork*.asm.txt' \
            -o -name '*IOSkywalkTxSubmissionQueue*packetSubmission*.asm.txt' \
            -o -name '*IOSkywalkTxSubmissionQueue*requestDequeue*.asm.txt' \) \
            -print 2>/dev/null | sort -u > "$TMP/methods"
    fi
    if [ ! -s "$TMP/methods" ] && [ -d "$HOME/src/kcabi" ]; then
        find "$HOME/src/kcabi" -type f \
            \( -name '*IOSkywalkTxSubmissionQueue*legacyDequeue*.asm.txt' \
            -o -name '*IOSkywalkTxSubmissionQueue*listDequeue*.asm.txt' \
            -o -name '*IOSkywalkTxSubmissionQueue*checkForWork*.asm.txt' \
            -o -name '*IOSkywalkTxSubmissionQueue*packetSubmission*.asm.txt' \
            -o -name '*IOSkywalkTxSubmissionQueue*requestDequeue*.asm.txt' \) \
            -print 2>/dev/null | sort -u > "$TMP/methods"
    fi
    echo "METHOD_FILE_COUNT: $(wc -l < "$TMP/methods" | tr -d ' ')"
    cat "$TMP/methods"
    echo

    echo "========== TX SUBMISSION METHOD BODIES =========="
    if [ -s "$TMP/methods" ]; then
        while IFS= read -r f; do
            echo
            echo "----- METHOD_FILE: $f -----"
            cat "$f"
        done < "$TMP/methods"
    else
        echo "TX_SUBMISSION_METHOD_ASSEMBLY_NOT_FOUND"
        echo "Expected method names: legacyDequeue, listDequeue, checkForWork, packetSubmission, requestDequeue"
    fi
    echo

    echo "========== CURRENT CALLBACK SOURCE =========="
    SRC="$PROJECT/driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCLSkywalkQueues.cpp"
    HPP="$PROJECT/driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCLSkywalkQueues.hpp"
    for file in "$HPP" "$SRC"; do
        echo "----- $file -----"
        if [ -f "$file" ]; then
            grep -n -A24 -B2 -E 'txSubmissionAction|txCompletionAction|rxSubmissionAction|rxCompletionAction' "$file" || true
        else
            echo "MISSING"
        fi
    done
    echo

    echo "========== STAGE 21 PRELIMINARY DECISION =========="
    if grep -q 'METHOD_FILE:' "$TMP/methods" 2>/dev/null; then
        echo "STATUS: TX_SUBMISSION_METHOD_EVIDENCE_COLLECTED"
        echo "NEXT: inspect callback invocation, argument list, result usage, and packet/slot count bounds."
    else
        echo "STATUS: BLOCKED_TX_SUBMISSION_ACTION_CALLSITE_NOT_COLLECTED"
        echo "NEXT: extend kcabi extraction to disassemble the missing IOSkywalkTxSubmissionQueue method bodies."
    fi
    echo "SOURCE_MODIFIED: NO"
    echo "QUEUE_REGISTRATION: STILL_DISABLED"
    echo "DATAPATH_ACTIVATION: BLOCKED"
} > "$OUT"

echo "Created: $OUT"

if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    SHA="$(gh api "repos/$REPO/contents/Development/output.log" --jq '.sha' 2>/dev/null || true)"
    B64="$(base64 < "$OUT" | tr -d '\n')"
    if [ -n "$SHA" ]; then
        gh api --method PUT "repos/$REPO/contents/Development/output.log" \
            -f message="Stage 21 TX submission action call-site audit" \
            -f content="$B64" -f sha="$SHA" >/dev/null
        echo "UPLOAD_STATUS: SUCCESS — https://github.com/$REPO/blob/main/Development/output.log"
    else
        echo "UPLOAD_STATUS: GH_AUTH_OK_BUT_OUTPUT_LOG_SHA_NOT_RETRIEVED"
    fi
else
    echo "UPLOAD_STATUS: GH_CLI_NOT_AUTHENTICATED — output.log is ready for your existing GitHub runlog uploader."
fi
