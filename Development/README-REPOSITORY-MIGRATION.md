# Development folder migration

## Current repository

- Canonical repository: https://github.com/shammu2bd/Realtek-WiFi-Native-macOS
- Active branch: main
- Current documentation and run scripts must use this repository.
- Imported path: `Development/`

## Historical source and provenance

- Original source repository at the time of migration: https://github.com/shammu2bd/BDIX-TV
- Source branch: main
- Pinned source commit: cde59714f5bd42284633da7a792056330f267eec
- Source ZIP SHA-256: aef6adc7b2786b18e822ff74a2fd401d1bbf11b2e57e302463fc65ba6c3f5287

The original source repository name is retained here only as migration provenance.
It is not the active project repository. Use the canonical repository above for
future downloads, stage scripts, logs, reports and source updates.

The complete tracked `Development/` directory was extracted from the pinned
source repository archive and merged into this repository. This included stage
history, `output.log`, audit reports, run folders, scripts, documentation and
source archives present at that pinned commit.

The copy-paste commands in `Development/README.md` now point to the canonical
repository. Active shell, Python and command scripts were also updated to use
the canonical repository where they publish or retrieve project files.
Historical logs and audit reports remain unchanged to preserve original evidence
and provenance.

This migration did not modify the driver source outside `Development/`, build a
kext, install or load a driver, or change OpenCore.
