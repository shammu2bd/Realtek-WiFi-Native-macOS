# Stage89 Local Automation

## Install once

From the Intel Hackintosh running macOS Sequoia 15.8.1 (24H32), run this once in Terminal:

```bash
curl -fsSL "https://raw.githubusercontent.com/shammu2bd/Realtek-WiFi-Native-macOS/main/Development/install-stage89-auto-runner.sh" | bash
```

The installer verifies the supervisor Git blob SHA, checks the local project path and GitHub CLI authentication, then installs and starts:

`~/Library/LaunchAgents/com.realtekwifi.stage89-auto-runner.plist`

## What it does

- Polls GitHub every 300 seconds and reads `Development/output.log`.
- Finds only the next sequential `stage89-vN-*.sh` runner.
- Requires both `AUTO_SAFE_READ_ONLY=YES` and `AUTO_SCOPE=STAGE89_AUDIT`.
- Also requires an exact filename + Git blob SHA entry in `Development/stage89-auto-allowlist.txt`.
- Executes at most one audit runner per poll.
- Verifies the new canonical checkpoint, manifest run ID and every artifact blob SHA before recording a local verified receipt.
- Keeps local logs under the project root at `run log/automation/`; individual stage output stays under `run log/stage89-vN/<run>/`.
- Uses macOS notifications for completion, errors and when the next approved runner is not yet published.

## Safety boundary

The supervisor does not pull or modify the source tree. It never builds, signs, installs, loads, tests hardware, changes OpenCore/SIP/NVRAM, or touches the known-good legacy kext/EFI. It is hard-locked to Stage89 audit versions and will not launch Stage90. A future runner must be separately reviewed, published and added to the SHA allowlist before the local agent will execute it.

This local agent cannot author future audit scripts by itself. It runs only scripts already published and explicitly pinned in the allowlist.

## Pause / resume / uninstall

Pause by creating the local STOP file:

```bash
touch "$HOME/Downloads/Realtek-WiFi-Native-macOS-Main (Local)/run log/automation/STOP"
```

Resume:

```bash
rm -f "$HOME/Downloads/Realtek-WiFi-Native-macOS-Main (Local)/run log/automation/STOP"
```

Uninstall the LaunchAgent (existing logs are preserved):

```bash
launchctl bootout "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.realtekwifi.stage89-auto-runner.plist" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/com.realtekwifi.stage89-auto-runner.plist"
```
