# Stage164 — third-party KEXT symbol-provider probe for IO80211WorkQueue

## Purpose
Stage163 found `IO80211WorkQueue::workQueue()` as an ordinary external symbol in the carved 24H32 IO80211Family image, but did not prove that the macOS KEXT dependency resolver can match that undefined reference to the provider. The selected public SDK also has no class declaration.

Stage164 builds a tiny throwaway x86_64 KEXT in a temporary directory. It references only the exact mangled factory symbol, uses the same `-static -nostdlib -kext -undefined dynamic_lookup` linker mode as the repository's native target, generates a temporary native Info.plist with the project's target-version dependency resolver, and asks `kmutil libraries` which system library KEXT provides the undefined symbol.

## Pinned inputs
- macOS 15.8.1, build 24H32, x86_64.
- BootKC SHA-256: `cd013c14a7f21dbb8181fb06c44e079de8646b6a674abe21f6e47f42e8979af3`.
- Source checkout HEAD: `3d02ef10e353bb80d032980ffe2e7d28b90fd7da`.
- Stage163 report blob SHA: `d5f10cd40dd568907bc0712afeb0554383b033ac`.
- The probe uses the legacy `RTL88WiFi.kext` Info.plist as input to `tools/generate-sequoia-native-plist.py`, the existing `kmod_info.c`, and the native target's existing `libkmod.a`; every generated file is created only under TMPDIR.

## Audit operations
1. Verify target OS/build/architecture, BootKC SHA, checkout HEAD, and Stage163 report blob SHA.
2. Compile a one-function C++ probe that references only `__ZN16IO80211WorkQueue9workQueueEv`.
3. Compile the project's kmod entry-point source into a temporary object.
4. Link a throwaway KEXT using the native Makefile's linker mode; do not call `make`, which would build project outputs.
5. Verify the resulting binary retains the exact undefined factory symbol and has a target-matched generated Info.plist.
6. Run `kmutil libraries -p <temporary-kext> --all-symbols` to determine the provider bundle and whether any imports are unresolved or multiply defined.
7. Require the `kmutil libraries` transcript to report the factory symbol, IO80211Family as a provider library, and a zero exit status before marking the provider-resolution gate passed.
8. Upload the complete temporary build and dependency-resolution transcript to `Development/Logs/` and verify the Git blob SHA.

## Interpretation
A successful `kmutil libraries` result identifying `com.apple.iokit.IO80211Family` for the exact factory symbol proves symbol-provider resolution through the declared system KEXT dependency for this 24H32 environment. It does not make the class a public KPI, prove compatibility on another build, or settle the factory's global-default reference semantics or PostOffice/timer-source lifetime. Those remain separate implementation gates.

## Safety
This is a temporary compile/link and metadata-resolution probe only. It does not build the real driver, modify any source/configuration, install or load a KEXT, stage an AuxKC, change OpenCore/EFI/SIP/NVRAM/security policy, or reboot. The temporary KEXT is removed on exit.
