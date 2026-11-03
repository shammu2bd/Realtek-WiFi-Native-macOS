# Fix: `llvm-objdump not found`

The ABI collection helper needs `llvm-objdump` to disassemble selected symbols from
the macOS kernel collection. This is a host development utility; it is not a
kext and is not installed into OpenCore or macOS system folders.

## Recommended: Homebrew LLVM 20

On the Intel Sequoia machine, run:

```sh
brew install llvm@20
```

Then rerun the collector:

```sh
bash tools/collect-sequoia-abi-24H32.sh
```

The updated helper checks Homebrew's `llvm@20` prefix automatically even though
Homebrew keeps LLVM keg-only and does not add it to the normal `PATH`.

If auto-detection does not find it, run explicitly:

```sh
export LLVM_OBJDUMP="$(brew --prefix llvm@20)/bin/llvm-objdump"
"$LLVM_OBJDUMP" --version
bash tools/collect-sequoia-abi-24H32.sh
```

The `--version` command should print an LLVM 20.x version.

## Alternative: MacPorts

```sh
sudo port install llvm-20
bash tools/collect-sequoia-abi-24H32.sh
```

## Notes

- Do not copy `llvm-objdump` into `/usr/bin` or `/System`.
- Do not change SIP, AMFI, OpenCore, or kernel-extension settings for this error.
- Installing LLVM does not modify the active Wi-Fi driver or the kernel collection.
