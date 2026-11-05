# Stage89 Local Automation

## Install / repair

Run once from Terminal on the Intel Hackintosh running macOS Sequoia 15.8.1 (24H32):

\`\`\`bash
curl -fsSL "https://raw.githubusercontent.com/shammu2bd/Realtek-WiFi-Native-macOS/main/Development/install-stage89-auto-runner.sh" | bash
\`\`\`

The installer checks GitHub CLI authentication, verifies the supervisor Git blob SHA, and migrates the project from the protected Downloads folder to:

\`~/Developer/Realtek-WiFi-Native-macOS-Main (Local)\`

It refuses to merge or overwrite if both the old and new project directories exist. The LaunchAgent executable, working directory, cache and supervisor logs live under:

\`~/Library/Application Support/RTL88WiFi-Automation/\`

This avoids macOS launchd's denial of access to an executable and working directory located inside Downloads. Stage output remains in the project's \`run log/<stage>/<run>/\` folder.

## What it does

- Polls GitHub every 300 seconds and reads \`Development/output.log\`.
- Finds only the next sequential \`stage89-vN-*.sh\` runner.
- Requires both \`AUTO_SAFE_READ_ONLY=YES\` and \`AUTO_SCOPE=STAGE89_AUDIT\`.
- Requires an exact filename and Git blob SHA entry in \`Development/stage89-auto-allowlist.txt\`.
- Executes at most one audit runner per poll.
- Verifies the new canonical checkpoint, manifest run ID and every artifact blob SHA before recording a local verified receipt.
- Sends macOS notifications for completion, failure and when the next approved runner has not yet been published.

## Safety boundary

The supervisor does not pull or modify the source tree. It never builds, signs, installs, loads, tests hardware, changes OpenCore/SIP/NVRAM, or touches the known-good legacy kext/EFI. It is hard-locked to Stage89 audit versions and will not launch Stage90. A future runner must be separately reviewed, published and added to the SHA allowlist before the local agent will execute it.

This local agent cannot author future audit scripts itself. It runs only scripts already published and individually pinned in the allowlist.

## Pause / resume / uninstall

Pause:

\`\`\`bash
touch "$HOME/Library/Application Support/RTL88WiFi-Automation/STOP"
\`\`\`

Resume:

\`\`\`bash
rm -f "$HOME/Library/Application Support/RTL88WiFi-Automation/STOP"
\`\`\`

Uninstall the LaunchAgent (logs and project are preserved):

\`\`\`bash
launchctl bootout "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.realtekwifi.stage89-auto-runner.plist" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/com.realtekwifi.stage89-auto-runner.plist"
\`\`\`
