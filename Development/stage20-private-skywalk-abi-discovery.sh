#!/bin/bash
set -u

REPO="shammu2bd/Realtek-WiFi-Native-macOS"
PROJECT="${RTL88_PROJECT:-$HOME/Downloads/RTL88WiFi-1.0.11-WCL-stage14-generic-skywalk-segment-abi}"
OUT="$PROJECT/output.log"
TMP="$(mktemp -d 2>/dev/null || mktemp -d -t rtl88-stage20)"
trap 'rm -rf "$TMP"' EXIT

if [ ! -d "$PROJECT" ]; then
    printf 'ERROR: project directory not found: %s\n' "$PROJECT" >&2
    exit 2
fi

DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p 2>/dev/null || true)}"
if [ -d "/Applications/Xcode_16.4.app/Contents/Developer" ]; then
    DEVELOPER_DIR="/Applications/Xcode_16.4.app/Contents/Developer"
fi
export DEVELOPER_DIR

SDKROOT="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
KCABI="$HOME/src/kcabi"

{
    echo "RTL88WiFi Stage 20 — Private Skywalk callback ABI discovery"
    echo "DATE: $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo "HOST: $(sw_vers -productVersion 2>/dev/null || echo unknown) / $(sw_vers -buildVersion 2>/dev/null || echo unknown)"
    echo "ARCH: $(uname -m)"
    echo "DEVELOPER_DIR: ${DEVELOPER_DIR:-NOT_FOUND}"
    echo "SDKROOT: ${SDKROOT:-NOT_FOUND}"
    echo "PROJECT: $PROJECT"
    echo "KCABI: $KCABI"
    echo

    echo "========== KDK INVENTORY =========="
    if [ -d /Library/Developer/KDKs ]; then
        find /Library/Developer/KDKs -maxdepth 3 -type d -name '*.kdk' -print 2>/dev/null
    else
        echo "KDK_ROOT_NOT_FOUND: /Library/Developer/KDKs"
    fi
    echo

    echo "========== KERNEL FRAMEWORK LOCATIONS =========="
    for p in \
        "/System/Library/Frameworks/Kernel.framework" \
        "/System/Library/PrivateFrameworks/Kernel.framework" \
        "$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/Library/Frameworks/Kernel.framework" \
        "$SDKROOT/System/Library/Frameworks/Kernel.framework" \
        "/System/Volumes/Preboot/Cryptexes/OS/System/Library/Frameworks/Kernel.framework"
    do
        if [ -e "$p" ]; then
            echo "FOUND: $p"
        else
            echo "NOT_FOUND: $p"
        fi
    done
    echo

    echo "========== SEARCH ROOTS =========="
    : > "$TMP/roots"
    for p in \
        "/Library/Developer/KDKs" \
        "/System/Library/Frameworks/Kernel.framework" \
        "/System/Library/PrivateFrameworks" \
        "$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/Library/Frameworks" \
        "$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/SDKs" \
        "$SDKROOT/System/Library/Frameworks/Kernel.framework" \
        "$HOME/src/kcabi" \
        "$PROJECT"
    do
        if [ -d "$p" ]; then
            printf '%s\n' "$p" >> "$TMP/roots"
        fi
    done
    sort -u "$TMP/roots" -o "$TMP/roots"
    cat "$TMP/roots"
    echo

    echo "========== SKYWalk HEADER / SOURCE FILE DISCOVERY =========="
    : > "$TMP/candidates"
    while IFS= read -r root; do
        find "$root" -type f \( \
            -iname 'IOSkywalk*.h' -o \
            -iname '*Skywalk*.h' -o \
            -iname 'IOSkywalk*.hpp' -o \
            -iname '*Skywalk*.hpp' -o \
            -iname 'IOSkywalk*.cpp' -o \
            -iname '*Skywalk*.cpp' -o \
            -iname '*skywalk*.swiftinterface' \
        \) -print 2>/dev/null >> "$TMP/candidates"
    done < "$TMP/roots"
    sort -u "$TMP/candidates" -o "$TMP/candidates"
    CANDIDATE_COUNT="$(wc -l < "$TMP/candidates" | tr -d ' ')"
    echo "CANDIDATE_FILE_COUNT: $CANDIDATE_COUNT"
    if [ "$CANDIDATE_COUNT" -eq 0 ]; then
        echo "NO_SKYWALK_HEADER_FILES_FOUND_IN_SEARCH_ROOTS"
    else
        cat "$TMP/candidates"
    fi
    echo

    echo "========== CALLBACK TYPE / FACTORY DECLARATION MATCHES =========="
    : > "$TMP/matches"
    if [ -s "$TMP/candidates" ]; then
        while IFS= read -r f; do
            grep -nEi 'typedef|using[[:space:]].*(Action|Callback)|Action[[:space:]]*\(|Callback[[:space:]]*\(|withPool|IOSkywalk(Tx|Rx)(Submission|Completion)Queue|IOReturn|UInt32|uint32_t|packetSubmission|gatedEnqueue|legacyDequeue' "$f" 2>/dev/null | sed "s#^#$f:#" >> "$TMP/matches" || true
        done < "$TMP/candidates"
    fi
    MATCH_COUNT="$(wc -l < "$TMP/matches" | tr -d ' ')"
    echo "DECLARATION_MATCH_LINE_COUNT: $MATCH_COUNT"
    if [ "$MATCH_COUNT" -gt 0 ]; then
        sed -n '1,500p' "$TMP/matches"
    else
        echo "NO_CALLBACK_TYPEDEF_OR_FACTORY_SIGNATURE_MATCHES_FOUND"
    fi
    echo
    echo "========== VERIFIED 24H32 KERNEL CALLBACK CALL-SITE SHAPES =========="
    echo "TX_SUBMISSION_ACTION: 5 arguments — exact typedef IOSkywalkTxSubmissionQueueAction in bundled MacKernelSDK; matches current project declaration/definition."
    echo "TX_QUERY_FREE_SPACE_HANDLER: separate 3-argument typedef IOSkywalkQueryFreeSpaceHandler (owner, queue, UInt32 *outSpace); the 3-register call in packetSubmission is this handler, NOT the queue action."
    echo "TX_COMPLETION_ACTION: 5 arguments — exact typedef IOSkywalkTxCompletionQueueAction; matches current project declaration/definition."
    echo "RX_SUBMISSION_ACTION: 5 arguments — exact typedef IOSkywalkRxSubmissionQueueAction; matches current project declaration/definition."
    echo "RX_COMPLETION_ACTION: 5 arguments — exact typedef IOSkywalkRxCompletionQueueAction; matches current project declaration/definition."
    echo "All four action typedefs return IOReturn in the bundled MacKernelSDK. The supplied 24H32 call sites show RX submission, RX completion and TX completion consuming EAX as packet/ring counts; TX submission action result semantics still need its own action-call-site check."
    echo "NOTE: distinguish the TX query-free-space helper from TX submission action; the previous Stage20 preliminary three-argument TX action label was incorrect."
    echo

    echo
    echo "========== EXACT BUNDLED SDK QUEUE ACTION TYPEDEFS =========="
    HDR="$PROJECT/driver/RTL88WiFi/MacKernelSDK/Headers/IOKit/skywalk"
    for pair in \
        "IOSkywalkTxSubmissionQueue.h:IOSkywalkQueryFreeSpaceHandler|IOSkywalkTxSubmissionQueueAction" \
        "IOSkywalkTxCompletionQueue.h:IOSkywalkTxCompletionQueueAction" \
        "IOSkywalkRxSubmissionQueue.h:IOSkywalkRxSubmissionQueueAction" \
        "IOSkywalkRxCompletionQueue.h:IOSkywalkRxCompletionQueueAction"
    do
        name="${pair%%:*}"
        pattern="${pair#*:}"
        file="$HDR/$name"
        echo "--- $name ---"
        if [ -f "$file" ]; then
            grep -nE "$pattern" "$file" || true
        else
            echo "MISSING: $file"
        fi
    done
    echo

    echo "========== KCABI SOURCE / HEADER SEARCH =========="
    if [ -d "$KCABI" ]; then
        find "$KCABI" -type f \( -name '*.h' -o -name '*.hpp' -o -name '*.cpp' -o -name '*.txt' -o -name '*.json' -o -name '*.yaml' \) -print 2>/dev/null > "$TMP/kcabi-files"
        echo "KCABI_TEXT_FILE_COUNT: $(wc -l < "$TMP/kcabi-files" | tr -d ' ')"
        while IFS= read -r f; do
            grep -nEi 'IOSkywalk(Tx|Rx)(Submission|Completion)Queue|withPool|callback|packetSubmission|gatedEnqueue|legacyDequeue|IOReturn|UInt32|uint32_t' "$f" 2>/dev/null | sed "s#^#$f:#" || true
        done < "$TMP/kcabi-files" | sed -n '1,500p'
    else
        echo "KCABI_DIRECTORY_NOT_FOUND"
    fi
    echo

    echo "========== CURRENT PROJECT CALLBACK DECLARATIONS =========="
    HEADER="$PROJECT/driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCLSkywalkQueues.hpp"
    SOURCE="$PROJECT/driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCLSkywalkQueues.cpp"
    if [ -f "$HEADER" ]; then
        grep -n -A5 -B1 -E 'txSubmissionAction|txCompletionAction|rxSubmissionAction|rxCompletionAction' "$HEADER" || true
    else
        echo "QUEUE_HEADER_NOT_FOUND: $HEADER"
    fi
    if [ -f "$SOURCE" ]; then
        grep -n -A22 -E 'RTW88WCLSkywalkQueues::(txSubmissionAction|txCompletionAction|rxSubmissionAction|rxCompletionAction)' "$SOURCE" || true
    else
        echo "QUEUE_SOURCE_NOT_FOUND: $SOURCE"
    fi
    echo

    echo "========== STAGE 20 DECISION =========="
    if [ "$MATCH_COUNT" -gt 0 ]; then
        echo "STATUS: REVIEW_DISCOVERED_DECLARATION_MATCHES"
        echo "NOTE: textual matches are candidates only; confirm typedef ownership and callback argument mapping before patching."
    else
        echo "STATUS: BLOCKED_PRIVATE_SKYWALK_CALLBACK_DECLARATIONS_NOT_LOCATED"
        echo "NEXT: obtain the 24H32 Kernel Development Kit or private Skywalk headers / class metadata."
    fi
    echo "SOURCE_MODIFIED: NO"
    echo "QUEUE_REGISTRATION: STILL_DISABLED"
    echo "DATAPATH_ACTIVATION: BLOCKED"
    echo
    echo "SAFETY: do not replace IOReturn with UInt32 or alter argument lists based only on guessed types; correlate declarations and kernel call sites first."
} > "$OUT"

echo "Created report: $OUT"

if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    SHA="$(gh api "repos/$REPO/contents/Development/output.log" --jq '.sha' 2>/dev/null || true)"
    B64="$(base64 < "$OUT" | tr -d '\n')"
    if [ -n "$SHA" ]; then
        gh api --method PUT "repos/$REPO/contents/Development/output.log" \
            -f message="Stage 20 private Skywalk callback ABI discovery" \
            -f content="$B64" -f sha="$SHA" >/dev/null
        echo "UPLOAD_STATUS: SUCCESS — https://github.com/$REPO/blob/main/Development/output.log"
    else
        echo "UPLOAD_STATUS: GH_AUTH_OK_BUT_OUTPUT_LOG_SHA_NOT_RETRIEVED"
    fi
else
    echo "UPLOAD_STATUS: GH_CLI_NOT_AUTHENTICATED — output.log is ready for the existing GitHub runlog uploader."
fi
