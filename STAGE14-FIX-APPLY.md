# Stage 14 collector fix — apply and run

This overlay fixes the missing `IOSkywalkMemorySegment` report by adding the
class to an isolated temporary copy of WTLKcAbi's `dump.py` `CLASSES` allow-list.
It does not edit `~/src/kcabi` / `~/src/WTLKcAbi`, the driver source, the Kext,
or OpenCore configuration.

## Apply

Extract the overlay ZIP into the existing Stage 14 project directory, keeping
the `tools/`, `tests/` and `docs/` folders in place. It contains only the files
changed for this fix plus this note.

## Validate and collect on the target Mac

Run from the Stage 14 project directory after the `runlog` helper has been
installed and `gh auth login` is complete:

```sh
runlog bash -lc '
cd "$HOME/Downloads/RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source" || exit 1
python3 tests/test-wcl-generic-skywalk-segment-ref-stage14.py &&
bash -n tools/collect-sequoia-abi-24H32-stage14.sh &&
tools/collect-sequoia-abi-24H32-stage14.sh build/sequoia-abi-24H32-stage14
'
```

The wrapper overwrites `~/Desktop/output.log` and updates
`shammu2bd/Realtek-WIFI-Native-macOS/output.log` after the command finishes. A successful
collector run also creates
`build/sequoia-abi-24H32-stage14/RTL88WiFi-Sequoia-24H32-stage14-generic-skywalk-segment-packet-kcabi.tar.gz`.
Upload that archive separately to the repository root; `runlog` syncs only the
log file.

Stage 14 remains pending until the target Mac run confirms that all eight
class method lists exist and both collection passes finish successfully.
