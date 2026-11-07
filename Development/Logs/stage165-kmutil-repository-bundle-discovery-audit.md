# Stage165 — explicit-repository kmutil bundle discovery and workqueue symbol-provider audit

## Purpose
Stage164 successfully compiled and linked a temporary KEXT and confirmed that its Mach-O retained the undefined import __ZN16IO80211WorkQueue9workQueueEv. Its kmutil libraries -p path --all-symbols call stopped before scanning symbols with KMErrorDomain Code 71: it could not find the temporary extension at the supplied path.

Stage165 addresses that specific discovery failure. The throwaway bundle is now created inside a dedicated temporary repository directory, and the query supplies both:
- -r temporary-repository (repository): a directory containing KEXT bundles.
- -p temporary-repository/bundle.kext (bundle-path): the exact bundle to include.

The runner performs both --all-symbols and --onedef-symbols queries. It requires successful return codes and the exact factory symbol plus com.apple.iokit.IO80211Family in the unique-provider output before reporting a pass.

## Pinned inputs
- macOS 15.8.1, build 24H32, x86_64.
- BootKC SHA-256: cd013c14a7f21dbb8181fb06c44e079de8646b6a674abe21f6e47f42e8979af3.
- Source checkout HEAD: 3d02ef10e353bb80d032980ffe2e7d28b90fd7da.
- Stage163 report blob SHA: d5f10cd40dd568907bc0712afeb0554383b033ac.
- Stage164 report blob SHA: 314ac400f81e698c2dfa3c216efd86d3f1e3765b.
- Temporary KEXT metadata is generated from the existing legacy plist and native controller header with tools/generate-sequoia-native-plist.py; no source plist is changed.

## Audit operations
1. Verify the target system, BootKC SHA, source HEAD, and pinned Stage163/164 GitHub report blob SHAs.
2. Generate the temporary native Info.plist, validate it with plutil -lint, and confirm its executable name.
3. Compile the existing kmod_info.c and a minimal C++ reference to the exact workqueue factory symbol.
4. Link a throwaway x86_64 KEXT under a dedicated temporary repository; verify the executable and undefined factory import.
5. Run kmutil libraries -r repository -p bundle --all-symbols.
6. Run the same discovery with --onedef-symbols to capture the symbol-to-library provider listing.
7. Require both calls to return zero and the unique-provider output to include the exact mangled factory symbol and com.apple.iokit.IO80211Family.
8. Verify the Git working-tree status fingerprint is unchanged and upload the report to Development/Logs/, then independently verify its Git blob SHA.

## Interpretation and limits
A successful unique-provider listing would establish that kmutil libraries identifies com.apple.iokit.IO80211Family as the unique symbol provider for this specific undefined factory reference on this exact 24H32 target. It would not make this private C++ class a public KPI, prove compatibility on another macOS build, or resolve the global default-workqueue semantics or PostOffice/timer-source lifetime.

If kmutil still rejects the bundle or does not list the exact symbol/provider, the runner reports REVIEW_REQUIRED; no inference that the symbol is unavailable should be made unless the output actually reports it unresolved.

## Safety boundary
This is a temporary compile/link and metadata-query audit only. All generated files are confined to TMPDIR and removed at exit. It does not modify project sources or tracked build outputs, install/load a KEXT, rebuild or stage an AuxKC, modify OpenCore/EFI/SIP/NVRAM/security settings, or reboot.
