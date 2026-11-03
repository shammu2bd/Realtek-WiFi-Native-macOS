# Stage 15 run checklist

From the Stage 14 project root, run through the `runlog` helper so the log is
saved on the Desktop and committed to `shammu2bd/Realtek-WIFI-Native-macOS`:

```sh
python3 tests/test-skywalk-packet-access-stage15.py && \
python3 tools/audit-skywalk-packet-access-stage15.py \
  --archive build/sequoia-abi-24H32-stage14/RTL88WiFi-Sequoia-24H32-stage14-generic-skywalk-segment-packet-kcabi.tar.gz \
  --out build/sequoia-abi-24H32-stage15
```

The updated `runlog` helper should upload the newly created Stage 15 `.tar.gz`
from the project build directory to the repository root automatically.


### Demangler compatibility fix

Some macOS `c++filt` builds expect the original Mach-O kernel symbol spelling
(`__Z...`), while GNU/LLVM tools commonly expect the normalized Itanium form
(`_Z...`). The Stage 15 demangler now tries both spellings and fails closed only
when neither form is recognized. The regression suite includes a simulated
Apple-style demangler check for this fallback.
