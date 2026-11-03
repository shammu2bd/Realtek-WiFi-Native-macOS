#!/bin/bash
# Added on 2026-10-24 for RTL88WiFi 1.0.2, rewritten for 1.0.5; see the repository NOTICE.md.
# RTL88WiFi report (read-only): what macOS asked the driver to do, what the
# driver answered, and the driver's own log.
#
#   bash tools/rtl88wifi-join-report.sh          # last 300 lines of the driver log
#   bash tools/rtl88wifi-join-report.sh 600      # last 600 lines
#   bash tools/rtl88wifi-join-report.sh all      # everything the driver kept
#
# Run it on the Mac that has the kext loaded, after the thing you want to
# investigate has happened (a failed join, a Wi-Fi off/on, ...) and before the
# next reboot: the driver keeps its log in memory only.
#
# Where the log comes from: the driver does NOT write these lines to the macOS
# system log (macOS shows kernel text from kexts as <private>, which is why
# `log show` finds nothing). It keeps its own 32 KB ring buffer and publishes
# it as the registry property DiagnosticLog, which is what this reads. The ring
# is small, so run the report soon after the event. It changes nothing.
#
# Privacy: MAC addresses are cut to their last two bytes and the network name is
# replaced by <hidden>. Only its length in bytes, and whether it contains
# non-ASCII characters (for example the curly apostrophe in "Name's iPhone"),
# are kept because those can matter. The driver never logs keys or passwords.

set -u
LINES="${1:-300}"
case "$LINES" in all) ;; ''|*[!0-9]*) LINES=300 ;; esac

# Value of a property on the RTL88WiFi registry entry (empty if absent).
reg() {
    ioreg -r -c RTL88WiFi -l -w0 2>/dev/null |
        sed -n -E 's/.*"'"$1"'" = (.*)$/\1/p' | head -1 | tr -d '"'
}

hexcode() { printf '0x%x' "$1" 2>/dev/null; }

# Every line of driver log that is printed goes through this: MAC addresses are
# cut to their last two bytes and the network name is removed.
redact() {
    sed -E \
        -e 's/([0-9a-fA-F]{2}:){4}([0-9a-fA-F]{2}:[0-9a-fA-F]{2})/xx:xx:xx:xx:\2/g' \
        -e 's/ssid=.* secure=/ssid=<hidden> secure=/'
}

# The driver ring buffer. Primary: the XML form of ioreg (-a), where a long
# multi-line string is stored as one <string> element. Fallback: the text form,
# where the lines may be joined with a literal backslash-n.
get_ring() {
    local xml
    xml=$(ioreg -r -c RTL88WiFi -l -a 2>/dev/null | awk '
        /<key>DiagnosticLog<\/key>/ { want = 1; next }
        want && !ins {
            if (index($0, "<string/>")) exit
            i = index($0, "<string>")
            if (i == 0) { want = 0; next }
            $0 = substr($0, i + 8); ins = 1
        }
        ins {
            j = index($0, "</string>")
            if (j) { print substr($0, 1, j - 1); exit }
            print
        }' | sed -e 's/&lt;/</g' -e 's/&gt;/>/g' -e 's/&quot;/"/g' -e "s/&apos;/'/g" -e 's/&amp;/\&/g')
    if [ -n "$xml" ]; then printf '%s\n' "$xml"; return; fi
    local txt
    txt=$(ioreg -r -c RTL88WiFi -l -w0 2>/dev/null |
        sed -n -E 's/.*"DiagnosticLog" = "(.*)"$/\1/p' | head -1 |
        awk '{ gsub(/\\n/, "\n"); print }')
    [ -n "$txt" ] && printf '%s\n' "$txt"     # command substitution drops trailing blank lines
}

# Turn "[ticks=N] text" into "  -12.3s  text": seconds before the newest line.
# (Intel Macs count ticks in nanoseconds; hw.tbfrequency gives the real rate.)
TB=$(sysctl -n hw.tbfrequency 2>/dev/null)
case "$TB" in ''|*[!0-9]*) TB=1000000000 ;; esac
annotate() {
    awk -v tb="$TB" '
        { lines[NR] = $0
          if (match($0, /^\[ticks=[0-9]+\]/)) {
              t = substr($0, 8, RLENGTH - 8) + 0; ticks[NR] = t; if (t > maxt) maxt = t } }
        END { for (i = 1; i <= NR; i++) {
                l = lines[i]
                if (i in ticks) { sub(/^\[ticks=[0-9]+\] ?/, "", l); printf "%+8.1fs  %s\n", (ticks[i] - maxt) / tb, l }
                else printf "%9s  %s\n", "", l } }'
}

echo "RTL88WiFi report"
echo

# --- Driver -------------------------------------------------------------------
BUILD=$(reg DriverBuild)
if [ -z "$BUILD" ]; then
    echo "The RTL88WiFi driver is not loaded (no registry entry). Nothing to report."
    exit 1
fi
echo "Driver"
echo "  DriverBuild        : $BUILD"
echo "  AWDL_RADIO_POLICY  : $(reg AWDL_RADIO_POLICY)"
echo "  PREFER_5GHZ_POLICY : $(reg PREFER_5GHZ_POLICY)"
echo "  RADIO_NOISE_SOURCE : $(reg RADIO_NOISE_SOURCE)"
echo

# --- What macOS asked for (registry: the most recent request only) -------------
LOWER=$(reg STA_ASSOC_INPUT_AUTH_LOWER)
UPPER=$(reg STA_ASSOC_INPUT_AUTH_UPPER)
KEYLEN=$(reg STA_ASSOC_INPUT_KEY_LEN)
SSIDLEN=$(reg STA_ASSOC_INPUT_SSID_LEN)
RET=$(reg STA_ASSOCIATE_CMD_RET)
RESULT_VALID=$(reg STA_ASSOCIATE_RESULT_VALID)
BADPMK=$(reg STA_ASSOCIATE_BAD_PMK_LEN)
HOST32=$(reg STA_ASSOC_HOST32_TRANSLATED)
HOST32RET=$(reg STA_ASSOC_HOST32_RET)

echo "Most recent join request from macOS (earlier attempts: see the log below)"
if [ -z "$UPPER" ] && [ -z "$LOWER" ]; then
    echo "  none recorded since boot (macOS has not asked the driver to join anything)"
else
    echo "  auth lower=$LOWER  (1 = Open System in the legacy Apple80211 ABI)"
    echo "  auth upper=$UPPER"
    printf '    meaning:'
    names=""
    if [ "$SSIDLEN" = "0" ]; then
        names=" unavailable (empty SSID; payload may use a different host ABI)"
    else
        [ $(( UPPER & 1 ))   -ne 0 ] && names="$names WPA"
        [ $(( UPPER & 2 ))   -ne 0 ] && names="$names WPA-PSK"
        [ $(( UPPER & 8 ))   -ne 0 ] && names="$names WPA2-PSK"
        [ $(( UPPER & 128 )) -ne 0 ] && names="$names PSK-SHA256"
        [ $(( UPPER & 32 ))  -ne 0 ] && names="$names 802.1X(enterprise)"
        [ $(( UPPER & 512 )) -ne 0 ] && names="$names WPA3-SAE"
        [ "$UPPER" = "0" ] && names=" none (open network)"
    fi
    echo "${names:- unrecognised bits}"
    echo "  key length=$KEYLEN bytes  (32 = a ready-made WPA2 key, which the driver needs)"
    echo "  SSID length=$SSIDLEN bytes"
    [ -n "$BADPMK" ] && echo "  STA_ASSOCIATE_BAD_PMK_LEN=$BADPMK"
    [ "$HOST32" = "Yes" ] && echo "  host ABI: newer 32-bit ASSOCIATE payload normalized (return $( [ -n "$HOST32RET" ] && hexcode "$HOST32RET" || echo 'n/a'))"
    echo
    if [ "$RESULT_VALID" = "No" ]; then
        echo "  Driver answer: not recorded for this request (no completed ASSOCIATE handler result)"
        RET_FOR_CASE=""
    else
        echo "  Driver answer: $( [ -n "$RET" ] && hexcode "$RET" || echo 'n/a')"
        RET_FOR_CASE=$( [ -n "$RET" ] && hexcode "$RET" || echo 'n/a')
    fi
    case "$RET_FOR_CASE" in
        0x0)        echo "    = accepted; the join started. If it still failed, the cause is in the log below." ;;
        0xe00002c7) echo "    = kIOReturnUnsupported: the driver REFUSED the request before sending anything." ;;
        0xe00002f0) echo "    = kIOReturnNotFound: the driver has not seen this network in its scan list." ;;
        0xe00002d5) echo "    = kIOReturnBusy: a previous join/scan was still in progress." ;;
        0xe00002d8) echo "    = kIOReturnNotReady: the radio was not ready." ;;
        0xe00002c2) echo "    = kIOReturnBadArgument: the request was malformed." ;;
        *)          echo "    = (unrecognised code)" ;;
    esac

    verdict=""
    if [ "$SSIDLEN" = "0" ] && [ "$LOWER" = "0" ] && [ "$UPPER" = "1" ]; then
        verdict="payload matches the newer 32-bit host ASSOCIATE layout misread as the older 16-bit Ventura struct; this is not evidence of SAE."
    elif [ "$SSIDLEN" = "0" ]; then
        verdict="association payload has an empty SSID; auth fields cannot be classified reliably until the host ABI is decoded."
    elif [ $(( UPPER & 512 )) -ne 0 ] && [ $(( UPPER & (2|8|128) )) -eq 0 ]; then
        verdict="macOS asked for WPA3-only (SAE). This driver has WPA3-SAE disabled, so the join is refused by design."
    elif [ "$LOWER" != "1" ]; then
        verdict="unsupported lower authentication value ($LOWER); this value alone does not identify WPA3."
    elif [ $(( UPPER & (2|8|128) )) -ne 0 ] && [ "$KEYLEN" != "32" ]; then
        verdict="macOS did not supply a 32-byte key (it sent $KEYLEN bytes). That points at a WPA3 or non-PSK join."
    elif [ $(( UPPER & 32 ))  -ne 0 ]; then
        verdict="Enterprise (802.1X) network: not supported."
    fi
    [ -n "$verdict" ] && { echo; echo "  >>> $verdict"; }
fi
echo

# --- Link now -----------------------------------------------------------------
echo "Link now"
IF=$(ioreg -r -c RTL88WiFiInterface -l -w0 2>/dev/null | sed -n -E 's/.*"BSD Name" = "([^"]*)".*/\1/p' | head -1)
echo "  interface : ${IF:-none}"
if [ -n "$IF" ] && command -v ifconfig >/dev/null 2>&1; then
    echo "  status    : $(ifconfig "$IF" 2>/dev/null | sed -n -E 's/.*status: //p')"
    if ifconfig "$IF" 2>/dev/null | grep -q 'inet '; then echo "  IPv4      : assigned"; else echo "  IPv4      : none"; fi
fi
echo "  channel   : $(reg RADIO_CHANNEL)"
echo "  signal    : $(reg RADIO_RSSI)"
echo

# --- Driver log (the ring buffer) ---------------------------------------------
RAW=$(get_ring | annotate)
RBYTES=$(reg DiagnosticLogBytes)
RWRAP=$(reg DiagnosticLogWrapped)

if [ -z "$RAW" ]; then
    echo "Driver log"
    echo "  (the driver's log buffer is empty or could not be read)"
    echo
    echo "---- end: please paste everything above ----"
    exit 0
fi

TOTAL=$(printf '%s\n' "$RAW" | grep -c '')
if [ "$RWRAP" = "Yes" ]; then
    echo "Driver log: the buffer has wrapped, so the oldest lines are gone (kept: $TOTAL lines)"
else
    echo "Driver log: complete since the driver loaded ($TOTAL lines${RBYTES:+, $RBYTES bytes})"
fi
echo

echo "Join attempts found in the log"
N=$(printf '%s\n' "$RAW" | grep -c 'ASSOCIATE request')
if [ "$N" = 0 ]; then
    echo "  none retained in the log buffer"
    if [ -n "$LOWER" ] || [ -n "$UPPER" ]; then
        echo "  note: registry input fields exist, but no matching full ASSOCIATE log line is retained; they may describe an early-rejected request or an earlier attempt."
    fi
else
    printf '%s\n' "$RAW" | grep 'ASSOCIATE request' | while IFS= read -r line; do
        up=$(printf '%s' "$line" | sed -n -E 's/.*upper=(0x[0-9a-fA-F]+).*/\1/p')
        lo=$(printf '%s' "$line" | sed -n -E 's/.*lower=([0-9]+).*/\1/p')
        kl=$(printf '%s' "$line" | sed -n -E 's/.*keylen=([0-9]+).*/\1/p')
        pin=$(printf '%s' "$line" | sed -n -E 's/.*pinned=([01]).*/\1/p')
        ts=$(printf '%s' "$line" | awk '{print $1}')
        nm=""
        [ $(( up & 2 ))   -ne 0 ] && nm="$nm WPA-PSK"
        [ $(( up & 8 ))   -ne 0 ] && nm="$nm WPA2-PSK"
        [ $(( up & 128 )) -ne 0 ] && nm="$nm PSK-SHA256"
        [ $(( up & 32 ))  -ne 0 ] && nm="$nm 802.1X"
        [ $(( up & 512 )) -ne 0 ] && nm="$nm WPA3-SAE"
        [ $(( up )) -eq 0 ] && nm=" open"
        echo "  $ts  security:${nm}  key=${kl} bytes  lower=${lo}  macOS named a specific BSSID: $( [ "$pin" = 1 ] && echo yes || echo no )"
    done
    REF=$(printf '%s\n' "$RAW" | grep -c 'ASSOCIATE refused')
    [ "$REF" != 0 ] && echo "  >>> the driver refused $REF request(s) by design; see the 'refused' lines below for why"
fi
echo

echo "Station MAC address changes (Private Wi-Fi address)"
PGET=$(reg STA_PRIVATE_MAC_GET_SEEN)
PSET=$(reg STA_PRIVATE_MAC_SET_SEEN)
PRET=$(reg STA_PRIVATE_MAC_LAST_RET)
echo "  selector ingress: GET=${PGET:-not seen}, SET=${PSET:-not seen}, last return=${PRET:-n/a}"
M=$(printf '%s\n' "$RAW" | grep -c 'station MAC updated\|PRIVATE_MAC')
if [ "$M" = 0 ]; then echo "  no Private MAC requests or station-address changes in the log"; else printf '%s\n' "$RAW" | grep 'station MAC updated\|PRIVATE_MAC' | tail -12 | redact | sed 's/^/  /'; fi
echo

echo "Uplink aggregation (A-MPDU / Block Ack)"
E=$(printf '%s\n' "$RAW" | grep -c 'ADDBA\|DELBA\|A-MPDU')
if [ "$E" = 0 ]; then
    echo "  no aggregation events in the log"
else
    printf '%s\n' "$RAW" | grep 'ADDBA\|DELBA\|A-MPDU' | tail -20 | redact | sed 's/^/  /'
fi
AGG_LAST=$(printf '%s\n' "$RAW" | grep 'DIAG sample' | tail -1 | sed -n -E 's/.*agg=([01]).*/\1/p')
[ -n "$AGG_LAST" ] && echo "  latest heartbeat: uplink aggregation is $( [ "$AGG_LAST" = 1 ] && echo ON || echo OFF )"
HB_UP=$(printf '%s\n' "$RAW" | grep 'DIAG sample' | grep -c 'visible=1')
HB_OFF=$(printf '%s\n' "$RAW" | grep 'DIAG sample' | grep -c 'visible=1 agg=0')
[ "$HB_UP" != 0 ] && echo "  heartbeats while connected: $HB_UP, of which with aggregation OFF: $HB_OFF"
DEL=$(printf '%s\n' "$RAW" | grep -c 'RX DELBA.*initiator=0')
if [ "$DEL" != 0 ]; then
    echo "  >>> the access point tore down the uplink aggregation agreement $DEL time(s)."
    echo "      Builds before 1.0.6 never asked for it again, so uploads stay slow until you reconnect."
fi
echo

echo "Key rekeys and key errors"
KR=$(printf '%s\n' "$RAW" | grep -c 'group key handshake\|M1 fresh=\|MIC check failed\|group M1 dropped\|stale group M1\|failed to unwrap\|M3 dropped\|group key install failed\|no GTK KDE\|key install failed')
if [ "$KR" = 0 ]; then echo "  none in the log"; else
    printf '%s\n' "$RAW" | grep 'group key handshake\|M1 fresh=\|MIC check failed\|group M1 dropped\|stale group M1\|failed to unwrap\|M3 dropped\|group key install failed\|no GTK KDE\|key install failed' | tail -15 | redact | sed 's/^/  /'
fi
echo

if [ "$LINES" = all ]; then SHOW=$RAW; else SHOW=$(printf '%s\n' "$RAW" | tail -n "$LINES"); fi
echo "Driver log (newest last; times are seconds before the newest line)"
# Keep the length / non-ASCII facts about the network name, then redact it.
SSIDRAW=$(printf '%s\n' "$RAW" | sed -n -E 's/.*ssid=(.*) secure=.*/\1/p' | tail -1)
if [ -n "$SSIDRAW" ]; then
    NBYTES=$(printf '%s' "$SSIDRAW" | LC_ALL=C wc -c | tr -d ' ')
    if printf '%s' "$SSIDRAW" | LC_ALL=C grep -q '[^ -~]'; then NONASCII=yes; else NONASCII=no; fi
    echo "  network name: $NBYTES bytes, non-ASCII characters: $NONASCII"
fi
printf '%s\n' "$SHOW" | redact | sed 's/^/  /'
echo
echo "---- end: please paste everything above ----"
