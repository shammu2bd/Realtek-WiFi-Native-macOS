#!/bin/bash
set -Eeuo pipefail
trap 'rc=$?; echo "STAGE27_ERROR: exit=$rc line=$LINENO" >&2; exit "$rc"' ERR
REPO=shammu2bd/Realtek-WiFi-Native-macOS
NAME=RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source
if [[ -n "${PROJECT_DIR:-}" ]] && [[ -f "${PROJECT_DIR:-}/driver/RTL88WiFi/Makefile" ]]; then PROJECT="$(cd "$PROJECT_DIR" && pwd -P)"
elif [[ -f "$PWD/driver/RTL88WiFi/Makefile" ]]; then PROJECT="$(pwd -P)"
elif [[ -f "$HOME/Downloads/$NAME/driver/RTL88WiFi/Makefile" ]]; then PROJECT="$HOME/Downloads/$NAME"
else echo "Cannot locate project"; exit 2; fi
command -v gh >/dev/null && gh auth status >/dev/null
STAGE="$PROJECT/build/stage27-tx-double-completion-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$STAGE"
REPORT="$STAGE/stage27-tx-double-completion-proof.txt"
python3 - "$PROJECT" "$REPORT" <<'PY'
from pathlib import Path
import hashlib,sys
project=Path(sys.argv[1]); out=Path(sys.argv[2]); driver=project/"driver/RTL88WiFi"
targets=["src/compat/linux/skbuff.h","src/compat/linux/skbuff_tx_completion.h","src/kext/RTW88IEEE80211.cpp","src/kext/RTW88IEEE80211.hpp","src/kext/wcl24h32/RTW88WCLTxCompletionSlots.hpp","src/kext/wcl24h32/RTW88WCLSkywalkTxAdapter.cpp","src/kext/wcl24h32/RTW88WCLSkywalkTxAdapter.hpp"]
r=["Stage27 — complete source files for TX duplicate-completion proof","SOURCE_CHANGES: NONE | BUILD: NOT RUN | INSTALL: NOT RUN | LOAD: NOT RUN | OPENCORE: UNCHANGED","KNOWN_GOOD_LEGACY_KEXT: NOT TOUCHED",""]
for rel in targets:
 p=driver/rel
 if not p.is_file(): r += ["MISSING: "+rel]; continue
 b=p.read_bytes()
 r += ["\n=== FILE "+rel+" SHA256 "+hashlib.sha256(b).hexdigest()+" BYTES "+str(len(b))+" ===",b.decode("utf-8","replace")]
r += ["\n=== REVIEW QUESTIONS ===","A. Does kfree_skb() atomically claim and dispatch the token before freeing skb? What are exact states and memory orders?","B. Does txDataFrame() free skb then return false on any branch? If yes, does outputPacketWithCompletion() also directly invoke callback?","C. Does TicketPool::complete() atomically reject duplicates without modifying ticket fields after first acceptance?","D. Can synchronous callback occur inside outputPacketWithCompletion() before submitPacket() returns? Does adapter retain remain valid?","E. Prove ticket states, packet retain/release, adapter retain/release, generation/reuse and late callback safety.","F. Trace every failure path: disconnected, invalid Ethernet frame, skb allocation, mbuf copy, token allocation/bind, backend synchronous drop, TX status, skb purge, reset and stop.","G. If any transition or lifetime cannot be proven, leave OPEN. No runtime activation is authorized.","STAGE27_STATUS: REVIEW_REQUIRED","ACTIVATION_GATE: BLOCKED"]
out.write_text("\n".join(r)+"\n")
print("STAGE27_REPORT_PATH:",out)
print("REPORT_BYTES:",out.stat().st_size)
PY
test -s "$REPORT"
BYTES=$(wc -c < "$REPORT" | tr -d ' ')
(( BYTES <= 900000 )) || { echo "Report exceeds upload cap: $BYTES"; exit 2; }
upload() {
 local file="$1" path="$2" msg="$3" payload="$4" response="$5" old put got
 old="$(gh api "repos/$REPO/contents/$path" --jq .sha 2>/dev/null || true)"
 python3 - "$file" "$old" "$msg" "$payload" <<'PY2'
import base64,json,pathlib,sys
f,s,m,p=sys.argv[1:]; d={"message":m,"content":base64.b64encode(pathlib.Path(f).read_bytes()).decode()}
if s:d["sha"]=s
pathlib.Path(p).write_text(json.dumps(d))
PY2
 gh api --method PUT "repos/$REPO/contents/$path" --input "$payload" > "$response"
 put="$(python3 - "$response" <<'PY2'
import json,sys
print(json.load(open(sys.argv[1]))["content"]["sha"])
PY2
)"
 got="$(gh api "repos/$REPO/contents/$path" --jq .sha)"
 [[ "$put" == "$got" ]] || { echo "Readback SHA mismatch: $path"; return 1; }
 echo "UPLOAD_VERIFIED $path $got"
 UPLOAD_SHA="$got"
}
upload "$REPORT" Development/stage27-tx-double-completion-proof.txt "Add Stage27 TX double-completion audit" "$STAGE/report.json" "$STAGE/report-response.json"
RPTSHA="$UPLOAD_SHA"
curl -fsSL "https://raw.githubusercontent.com/$REPO/main/Development/output.log" -o "$STAGE/old.log"
python3 - "$STAGE/old.log" "$PROJECT/output.log" "$RPTSHA" "$BYTES" <<'PY2'
import pathlib,sys
old=pathlib.Path(sys.argv[1]).read_text(errors="replace")
mark="========== STAGE27 TX DOUBLE-COMPLETION PROOF =========="
if mark in old:old=old[:old.index(mark)].rstrip()+"\n"
old+="\n"+mark+"\nSTAGE27_REPORT: Development/stage27-tx-double-completion-proof.txt\nSTAGE27_REPORT_BLOB_SHA: "+sys.argv[3]+"\nSTAGE27_REPORT_BYTES: "+sys.argv[4]+"\nSTAGE27_STATUS: REVIEW_REQUIRED\nACTIVATION_GATE: BLOCKED\nSOURCE_CHANGES: NONE | BUILD: NOT RUN | INSTALL: NOT RUN | LOAD: NOT RUN | OPENCORE_CHANGE: NONE\nKNOWN_GOOD_LEGACY_KEXT: NOT TOUCHED\n"
pathlib.Path(sys.argv[2]).write_text(old)
PY2
upload "$PROJECT/output.log" Development/output.log "Record Stage27 TX double-completion audit" "$STAGE/log.json" "$STAGE/log-response.json"
echo "CANONICAL_OUTPUT_LOG_UPLOAD: SUCCESS"
echo "STAGE27_STATUS: REVIEW_REQUIRED"
echo "ACTIVATION_GATE: BLOCKED"
