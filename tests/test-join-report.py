"""Check tools/rtl88wifi-join-report.sh against fake ioreg / ifconfig / sysctl.

The script is read-only and only talks to ioreg, ifconfig and sysctl, so the test
puts fakes for those on PATH and feeds it the situations it exists to explain
(WPA3-only request, normal WPA2, network not in the scan list, driver not
loaded, a network name with a curly apostrophe).  The driver log is read from
the DiagnosticLog registry property (ioreg -a XML, with a text fallback), exactly
as on a Mac; the system log is not used because macOS shows kext text as
<private>.  Privacy promises are checked too: MAC addresses are cut to the last
two bytes and the network name is never printed.  Works with the macOS system
bash 3.2 and BSD sed/awk as well as GNU.
"""
from pathlib import Path
import os, plistlib, subprocess, tempfile, textwrap

root = Path(__file__).resolve().parents[1]
script = root / 'tools/rtl88wifi-join-report.sh'

IOREG_TMPL = '''  |   "DriverBuild" = "1.0.5-rtl88wifi-r16-20261025"
  |   "AWDL_RADIO_POLICY" = "disabled"
  |   "PREFER_5GHZ_POLICY" = "enabled"
  |   "RADIO_NOISE_SOURCE" = "estimated"
  |   "RADIO_CHANNEL" = 149
  |   "RADIO_RSSI" = "-31"
{props}'''


def props(**kw):
    return ''.join('  |   "%s" = %s\n' % (k, v) for k, v in kw.items())


def ring(*lines, t0=1_000_000_000, step=1_000_000_000):
    """Driver ring text: '[ticks=N] message' lines, one per second (Intel: 1 tick = 1 ns)."""
    return ''.join('[ticks=%d] %s\n' % (t0 + i * step, l) for i, l in enumerate(lines))


def run(ioreg_text, ring_text='', loaded=True, arg=None, mode='xml', wrapped=False):
    with tempfile.TemporaryDirectory(prefix='rtw88-report-') as td:
        td = Path(td)
        text = ioreg_text
        if ring_text:
            text += '  |   "DiagnosticLogBytes" = %d\n  |   "DiagnosticLogWrapped" = %s\n' % (
                len(ring_text), 'Yes' if wrapped else 'No')
        if mode == 'text' and ring_text:      # one line, newlines shown as a literal backslash-n
            text += '  |   "DiagnosticLog" = "%s"\n' % ring_text.replace('\n', '\\n')
        (td / 'ioreg_text').write_text(text)
        xml = plistlib.dumps([{'DriverBuild': '1.0.5', 'DiagnosticLog': ring_text,
                               'IORegistryEntryChildren': []}])
        (td / 'ioreg_xml').write_bytes(xml)
        (td / 'ioreg').write_text(textwrap.dedent('''\
            #!/bin/sh
            case "$*" in
              *RTL88WiFiInterface*) echo '  |   "BSD Name" = "en0"' ;;
              *" -a"*) [ "%s" = xml ] && [ "%s" = 1 ] && cat "%s/ioreg_xml" ;;
              *) [ "%s" = 1 ] && cat "%s/ioreg_text" ;;
            esac
            ''' % (mode, 1 if loaded else 0, td, 1 if loaded else 0, td)))
        (td / 'ifconfig').write_text('#!/bin/sh\necho "\\tstatus: inactive"\n')
        (td / 'sysctl').write_text('#!/bin/sh\necho 1000000000\n')
        for n in ('ioreg', 'ifconfig', 'sysctl'):
            os.chmod(td / n, 0o755)
        env = dict(os.environ, PATH='%s:%s' % (td, os.environ['PATH']))
        cmd = ['bash', str(script)] + ([arg] if arg else [])
        r = subprocess.run(cmd, capture_output=True, text=True, env=env)
        return r.returncode, r.stdout


def check(cond, msg, out):
    if not cond:
        print(out)
        raise SystemExit('FAIL: ' + msg)


# 1. WPA3-only request: refused by design, and the report must say so.
rc, out = run(IOREG_TMPL.format(props=props(
    STA_ASSOC_INPUT_AUTH_LOWER=1, STA_ASSOC_INPUT_AUTH_UPPER=512,
    STA_ASSOC_INPUT_KEY_LEN=11, STA_ASSOC_INPUT_SSID_LEN=14,
    STA_ASSOCIATE_CMD_RET=3758097095)))
check(rc == 0 and 'WPA3-SAE' in out and '0xe00002c7' in out and 'kIOReturnUnsupported' in out, 'WPA3-only decode', out)
check('asked for WPA3-only (SAE)' in out, 'WPA3-only verdict', out)

# 2. SAE arrives with a non-open lower auth type.
rc, out = run(IOREG_TMPL.format(props=props(
    STA_ASSOC_INPUT_AUTH_LOWER=3, STA_ASSOC_INPUT_AUTH_UPPER=512,
    STA_ASSOC_INPUT_KEY_LEN=0, STA_ASSOC_INPUT_SSID_LEN=8,
    STA_ASSOCIATE_CMD_RET=3758097095)))
check('asked for WPA3-only' in out or 'non-open lower auth' in out, 'non-open lower auth verdict', out)

# 2b. The newer 32-bit host ABI misread as the Ventura 16-bit struct looks like
# lower=0, upper=1, SSID length=0. It must not be mislabeled as WPA3.
rc, out = run(IOREG_TMPL.format(props=props(
    STA_ASSOC_INPUT_AUTH_LOWER=0, STA_ASSOC_INPUT_AUTH_UPPER=1,
    STA_ASSOC_INPUT_KEY_LEN=0, STA_ASSOC_INPUT_SSID_LEN=0,
    STA_ASSOCIATE_CMD_RET=3758097090)))
check('newer 32-bit host ASSOCIATE layout' in out and 'not evidence of SAE' in out,
      '32-bit host ABI signature', out)
check('WPA3-only' not in out, 'do not mislabel ABI signature as WPA3', out)

# 3. Normal WPA2: accepted, and there must be no refusal verdict.
rc, out = run(IOREG_TMPL.format(props=props(
    STA_ASSOC_INPUT_AUTH_LOWER=1, STA_ASSOC_INPUT_AUTH_UPPER=8,
    STA_ASSOC_INPUT_KEY_LEN=32, STA_ASSOC_INPUT_SSID_LEN=6,
    STA_ASSOCIATE_CMD_RET=0)))
check('WPA2-PSK' in out and 'accepted; the join started' in out and '>>>' not in out, 'normal WPA2', out)

# 4. WPA2/WPA3 transition: PSK bit present with a 32-byte key -> no refusal.
rc, out = run(IOREG_TMPL.format(props=props(
    STA_ASSOC_INPUT_AUTH_LOWER=1, STA_ASSOC_INPUT_AUTH_UPPER=520,
    STA_ASSOC_INPUT_KEY_LEN=32, STA_ASSOC_INPUT_SSID_LEN=6, STA_ASSOCIATE_CMD_RET=0)))
check('WPA2-PSK' in out and 'WPA3-SAE' in out and '>>>' not in out, 'transition mode', out)

# 5. Network not in the driver's scan list.
rc, out = run(IOREG_TMPL.format(props=props(
    STA_ASSOC_INPUT_AUTH_LOWER=1, STA_ASSOC_INPUT_AUTH_UPPER=8,
    STA_ASSOC_INPUT_KEY_LEN=32, STA_ASSOC_INPUT_SSID_LEN=6, STA_ASSOCIATE_CMD_RET=3758097136)))
check('kIOReturnNotFound' in out and 'not seen this network' in out, 'not found decode', out)

# 6. PSK requested but macOS did not supply a 32-byte key.
rc, out = run(IOREG_TMPL.format(props=props(
    STA_ASSOC_INPUT_AUTH_LOWER=1, STA_ASSOC_INPUT_AUTH_UPPER=8,
    STA_ASSOC_INPUT_KEY_LEN=12, STA_ASSOC_INPUT_SSID_LEN=6,
    STA_ASSOCIATE_BAD_PMK_LEN=12, STA_ASSOCIATE_CMD_RET=3758097095)))
check('did not supply a 32-byte key (it sent 12 bytes)' in out, 'bad key length verdict', out)

# 6b. A false validity flag must stop a stale previous success from being
# presented as the result of a new malformed request.
rc, out = run(IOREG_TMPL.format(props=props(
    STA_ASSOC_INPUT_AUTH_LOWER=0, STA_ASSOC_INPUT_AUTH_UPPER=1,
    STA_ASSOC_INPUT_KEY_LEN=0, STA_ASSOC_INPUT_SSID_LEN=0,
    STA_ASSOCIATE_CMD_RET=0, STA_ASSOCIATE_RESULT_VALID='No')))
check('not recorded for this request' in out and 'accepted; the join started' not in out,
      'stale join result suppressed', out)

# 7. No join recorded yet; and an empty ring is reported as such.
rc, out = run(IOREG_TMPL.format(props=''))
check('none recorded since boot' in out and 'buffer is empty or could not be read' in out, 'no join / empty ring', out)

# 8. Driver not loaded: clear message, non-zero exit.
rc, out = run('', loaded=False)
check(rc == 1 and 'not loaded' in out, 'driver not loaded', out)

# 9. Ring: per-attempt summary, refusal count, relative times, pick line, MAC section.
R = ring(
    'RTL88WiFi: ASSOCIATE request lower=1 upper=0x200 keylen=0 ssidLen=12 pinned=0',
    'RTL88WiFi: ASSOCIATE refused: auth lower=1 upper=0x200 is not open/PSK (WPA3-SAE or another unsupported type)',
    'RTL88WiFi: station MAC updated to 02:11:22:33:44:55',
    'RTL88WiFi: ASSOCIATE request lower=1 upper=0x8 keylen=32 ssidLen=8 pinned=1',
    'rtw88: connect pick pinned=1 nodes24=1 nodes5=1 upgraded=1 -> 5 GHz',
    'RTL88WiFi: PRIVATE_MAC get enabled=1 flags=0x0 interval=0s')
rc, out = run(IOREG_TMPL.format(props=''), R)
check('complete since the driver loaded (6 lines' in out, 'ring header', out)
check('security: WPA3-SAE  key=0 bytes' in out and 'security: WPA2-PSK  key=32 bytes' in out, 'attempt decode', out)
check('named a specific BSSID: no' in out and 'named a specific BSSID: yes' in out, 'pinned decode', out)
check('the driver refused 1 request(s) by design' in out, 'refusal count', out)
check('connect pick pinned=1 nodes24=1 nodes5=1 upgraded=1 -> 5 GHz' in out, 'pick line kept', out)
check('-5.0s' in out and '+0.0s' in out and '-2.0s' in out, 'relative times', out)
check('Station MAC address changes' in out and 'station MAC updated to xx:xx:xx:xx:44:55' in out
      and 'PRIVATE_MAC get enabled=1' in out, 'MAC section', out)
check('02:11:22:33' not in out, 'MAC leaked', out)

# 9b. Aggregation and rekey sections: a mesh tore the uplink agreement down, aggregation stayed off for a long time.
R = ring(
    'rtw88: TX ADDBA accepted (tid=0) — uplink A-MPDU on',
    'rtw88: DIAG sample=10 state=5 visible=1 agg=1 rx_frames=100 be_avail=200 stalled=0',
    'rtw88: group key handshake gtk_idx=2 gtk_len=16 duplicate=0 G2 submission=1',
    'rtw88: RX DELBA tid=0 initiator=0 reason=39 uplink_was_active=1',
    'rtw88: DIAG sample=20 state=5 visible=1 agg=0 rx_frames=300 be_avail=250 stalled=0',
    'rtw88: DIAG sample=30 state=5 visible=1 agg=0 rx_frames=500 be_avail=250 stalled=0',
    'rtw88: EAPOL group M1 MIC check failed')
rc, out = run(IOREG_TMPL.format(props=''), R)
check('Uplink aggregation (A-MPDU / Block Ack)' in out and 'RX DELBA tid=0 initiator=0 reason=39' in out, 'aggregation section', out)
check('latest heartbeat: uplink aggregation is OFF' in out, 'latest agg flag', out)
check('heartbeats while connected: 3, of which with aggregation OFF: 2' in out, 'agg heartbeat counts', out)
check('tore down the uplink aggregation agreement 1 time(s)' in out, 'DELBA verdict', out)
check('Key rekeys and key errors' in out and 'group key handshake gtk_idx=2' in out and 'group M1 MIC check failed' in out, 'rekey section', out)
# healthy link: aggregation on, no DELBA -> no verdict
R = ring('rtw88: TX ADDBA accepted (tid=0) — uplink A-MPDU on',
         'rtw88: DIAG sample=10 state=5 visible=1 agg=1 rx_frames=100 be_avail=200 stalled=0')
rc, out = run(IOREG_TMPL.format(props=''), R)
check('aggregation is ON' in out and 'tore down' not in out and 'with aggregation OFF: 0' in out, 'healthy link', out)
rc, out = run(IOREG_TMPL.format(props=''), ring('rtw88: something else'))
check('no aggregation events in the log' in out and 'Key rekeys and key errors' in out, 'no events', out)

# 10. Redaction and network-name facts (7+3+1+1+6 = 18 bytes: the curly apostrophe is 3).
R = ring('RTL88WiFi: ASSOCIATE internal-RSN ssid=Shamiul\u2019s iPhone secure=1 keylen=32 ret=0x0',
         'rtw88: join stage=assoc-rejected failed on aa:bb:cc:dd:ee:01 -- trying 11:22:33:44:55:66 ch=149 rssi=-31')
rc, out = run(IOREG_TMPL.format(props=''), R)
check('Shamiul' not in out and 'iPhone' not in out, 'network name leaked', out)
check('ssid=<hidden> secure=1' in out, 'ssid not redacted', out)
check('network name: 18 bytes, non-ASCII characters: yes' in out, 'ssid facts', out)
check('xx:xx:xx:xx:ee:01' in out and 'xx:xx:xx:xx:55:66' in out, 'mac redaction', out)
check('aa:bb:cc:dd' not in out and '11:22:33:44' not in out, 'mac leaked', out)

# 11. XML escaping round-trips (& < > " ' inside the ring).
R = ring('rtw88: odd text <a> & "b" \'c\' > d')
rc, out = run(IOREG_TMPL.format(props=''), R)
check('odd text <a> & "b" \'c\' > d' in out, 'xml unescape', out)

# 12. Text fallback when ioreg -a gives nothing (older ioreg): literal backslash-n becomes newlines.
R = ring('RTL88WiFi: ASSOCIATE request lower=1 upper=0x8 keylen=32 ssidLen=8 pinned=0', 'rtw88: second line')
rc, out = run(IOREG_TMPL.format(props=''), R, mode='text')
check('security: WPA2-PSK' in out and 'rtw88: second line' in out and 'complete since the driver loaded (2 lines' in out,
      'text fallback', out)

# 13. Wrapped ring is flagged.
rc, out = run(IOREG_TMPL.format(props=''), ring('rtw88: x'), wrapped=True)
check('the buffer has wrapped' in out, 'wrapped flag', out)

# 14. Line limit: default 300, a number, "all", junk falls back to the default.
big = ring(*['rtw88: line %03d' % i for i in range(400)], step=1_000_000)
def shown(o): return sum(1 for l in o.splitlines() if 'rtw88: line ' in l)
rc, out = run(IOREG_TMPL.format(props=''), big)
check(shown(out) == 300 and 'rtw88: line 399' in out and 'rtw88: line 099' not in out, 'default 300 lines', out)
rc, out = run(IOREG_TMPL.format(props=''), big, arg='50')
check(shown(out) == 50, 'numeric limit', out)
rc, out = run(IOREG_TMPL.format(props=''), big, arg='all')
check(shown(out) == 400, 'all lines', out)
rc, out = run(IOREG_TMPL.format(props=''), big, arg='banana')
check(shown(out) == 300, 'junk arg', out)

print('PASS: report decodes WPA3-only / non-open lower auth / missing 32-byte key / NotFound / accepted / '
      'transition-mode requests; reads the driver ring from ioreg XML (with unescaping) and from the text fallback; '
      'summarises each join attempt and refusal, shows relative times and the MAC-address section, flags a wrapped ring, '
      'honours line limits; never prints the network name or more than the last two MAC bytes')
