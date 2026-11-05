# Makefile for RTL88WiFi (derived from the upstream rtw88-macos build)
.DEFAULT_GOAL := rtl88wifi
#
# Prerequisites:
#   Xcode Command Line Tools
#   macOS SDK (comes with Xcode)
#   IOKit headers (in SDK)
#
# Usage:
#   make              — build kext bundle + rtw88ctl  →  build/out/
#   make kext         — build kext only
#   make ctl          — build rtw88ctl only
#   make install      — copy build/out/rtw88.kext to /Library/Extensions
#   make load         — kextutil (unsigned, requires SIP kext loading enabled)
#   make unload       — kextunload
#   make clean        — remove build/

HOST_CPUS := $(shell sysctl -n hw.logicalcpu 2>/dev/null || echo 4)
MAKEFLAGS += -j$(HOST_CPUS)

# ------------------------------------------------------------------ #
# Paths                                                               #
# ------------------------------------------------------------------ #

PROJ_ROOT    := $(shell pwd)
LINUX_SRC    := $(PROJ_ROOT)/../rtw88-stable/drivers/net/wireless/realtek/rtw88
COMPAT_DIR   := $(PROJ_ROOT)/src/compat
KEXT_SRC     := $(PROJ_ROOT)/src/kext
FIRMWARE_DIR := $(PROJ_ROOT)/firmware
CTL_DIR      := $(PROJ_ROOT)/ctl

BUILD_DIR    := $(PROJ_ROOT)/build
OUT_DIR      := $(BUILD_DIR)/out

# Source bundle: Info.plist + Resources skeleton (tracked in git)
KEXT_SKEL    := $(PROJ_ROOT)/rtw88.kext

# Output bundle: fully assembled kext ready for OpenCore / kextutil
OUT_KEXT     := $(OUT_DIR)/rtw88.kext
OUT_KEXT_BIN := $(OUT_KEXT)/Contents/MacOS/rtw88
OUT_CTL      := $(OUT_DIR)/rtw88ctl

# ------------------------------------------------------------------ #
# Toolchain                                                           #
# ------------------------------------------------------------------ #

SDK          := $(shell xcrun --show-sdk-path)
MKSDK        := $(PROJ_ROOT)/MacKernelSDK
ARCH         := -arch x86_64
MINOS        := -mmacosx-version-min=13.0

CC           := xcrun clang
CXX          := xcrun clang++
LD           := xcrun clang++

KEXT_FLAGS   := -fno-exceptions -fno-rtti \
                -fno-stack-protector -mkernel \
                -MMD -MP \
                $(ARCH) $(MINOS) \
                -ffile-prefix-map=$(PROJ_ROOT)=driver/RTL88WiFi \
                -fdebug-prefix-map=$(PROJ_ROOT)=driver/RTL88WiFi \
                -isysroot $(SDK) \
                -I$(MKSDK)/Headers \
                -I$(SDK)/System/Library/Frameworks/Kernel.framework/Headers

# Compat include path overrides ALL linux/ and net/ headers
# so the Linux driver C files find our shims instead.
COMPAT_FLAGS := \
    -I$(COMPAT_DIR) \
    -I$(COMPAT_DIR)/linux \
    -I$(PROJ_ROOT)/src/kext

# C flags for Linux driver files
DRIVER_CFLAGS := \
    $(KEXT_FLAGS) \
    $(COMPAT_FLAGS) \
    -include $(COMPAT_DIR)/rtw88_compat.h \
    -I$(LINUX_SRC) \
    -DRTW88_MACOS=1 \
    -D__KERNEL__ \
    -DCONFIG_RTW88_PCI=1 \
    -DCONFIG_RTW88_8822B=1 \
    -DCONFIG_RTW88_8822BE=1 \
    -DCONFIG_RTW88_8822C=1 \
    -DCONFIG_RTW88_8822CE=1 \
    -DCONFIG_RTW88_8821C=1 \
    -DCONFIG_RTW88_8821CE=1 \
    -Werror=implicit-function-declaration \
    -Werror=int-conversion \
    -Werror=incompatible-pointer-types \
    -Wno-unused-variable \
    -Wno-unused-function

# C++ flags for kext wrapper files (-fapple-kext only for C++)
KEXT_CXXFLAGS := \
    $(KEXT_FLAGS) \
    -fapple-kext \
    $(COMPAT_FLAGS) \
    -std=c++17 \
    -DKERNEL \
    -Wno-deprecated-declarations \
    -Wno-nullability-completeness

# ------------------------------------------------------------------ #
# Source files                                                         #
# ------------------------------------------------------------------ #

# Linux driver core C files (PCIe-only transport; compiled with compat headers)
DRIVER_SRCS := \
    $(LINUX_SRC)/main.c \
    $(LINUX_SRC)/mac.c \
    $(LINUX_SRC)/phy.c \
    $(LINUX_SRC)/fw.c \
    $(LINUX_SRC)/tx.c \
    $(LINUX_SRC)/rx.c \
    $(LINUX_SRC)/sec.c \
    $(LINUX_SRC)/efuse.c \
    $(LINUX_SRC)/coex.c \
    $(LINUX_SRC)/ps.c \
    $(LINUX_SRC)/regd.c \
    $(LINUX_SRC)/bf.c \
    $(LINUX_SRC)/sar.c \
    $(LINUX_SRC)/util.c \
    $(LINUX_SRC)/pci.c \
    $(LINUX_SRC)/mac80211.c

# Chip-specific C files (PCIe chip cores + PCIe frontends only)
CHIP_SRCS := \
    $(LINUX_SRC)/rtw8822b.c \
    $(LINUX_SRC)/rtw8822b_table.c \
    $(LINUX_SRC)/rtw8822be.c \
    $(LINUX_SRC)/rtw8822c.c \
    $(LINUX_SRC)/rtw8822c_table.c \
    $(LINUX_SRC)/rtw8822ce.c \
    $(LINUX_SRC)/rtw8821c.c \
    $(LINUX_SRC)/rtw8821c_table.c \
    $(LINUX_SRC)/rtw8821ce.c

# Compat C implementation
COMPAT_SRCS := \
    $(COMPAT_DIR)/rtw88_thread_call.c \
    $(COMPAT_DIR)/rtw88_compat.c

# Firmware loader — compiled with system headers only (no Linux compat headers)
# fw_blobs.c is auto-generated from firmware/*.bin before compilation
FIRMWARE_SRCS := \
    $(COMPAT_DIR)/rtw88_firmware.c \
    $(COMPAT_DIR)/fw_blobs.c

FW_BLOBS_C := $(COMPAT_DIR)/fw_blobs.c

# kmod_info.c — defines _kmod_info (required by kmutil/kextutil)
KMOD_SRCS := \
    $(KEXT_SRC)/kmod_info.c

# IOKit C++ wrapper
# PCIe-only project: USB/SDIO device wrappers and transport backends are intentionally excluded
KEXT_SRCS := \
    $(KEXT_SRC)/RTW88Kext.cpp \
    $(KEXT_SRC)/RTW88PCIDevice.cpp \
    $(KEXT_SRC)/RTW88UserClient.cpp \
    $(KEXT_SRC)/RTW88IEEE80211.cpp

# ------------------------------------------------------------------ #
# Object files                                                         #
# ------------------------------------------------------------------ #

DRIVER_OBJS   := $(patsubst $(LINUX_SRC)/%.c,  $(BUILD_DIR)/driver/%.o, $(DRIVER_SRCS))
CHIP_OBJS     := $(patsubst $(LINUX_SRC)/%.c,  $(BUILD_DIR)/driver/%.o, $(CHIP_SRCS))
COMPAT_OBJS   := $(patsubst $(COMPAT_DIR)/%.c, $(BUILD_DIR)/compat/%.o, $(COMPAT_SRCS))
FIRMWARE_OBJS := $(patsubst $(COMPAT_DIR)/%.c, $(BUILD_DIR)/compat/%.o, $(FIRMWARE_SRCS))
KMOD_OBJS   := $(patsubst $(KEXT_SRC)/%.c,   $(BUILD_DIR)/kext/%.o,   $(KMOD_SRCS))
KEXT_OBJS   := $(patsubst $(KEXT_SRC)/%.cpp, $(BUILD_DIR)/kext/%.o,   $(KEXT_SRCS))

ALL_OBJS    := $(DRIVER_OBJS) $(CHIP_OBJS) $(COMPAT_OBJS) $(FIRMWARE_OBJS) $(KMOD_OBJS) $(KEXT_OBJS)

# ------------------------------------------------------------------ #
# Linker flags                                                         #
# ------------------------------------------------------------------ #

KEXT_LDFLAGS := \
    $(ARCH) \
    -static \
    -nostdlib \
    -Xlinker -kext \
    $(MKSDK)/Library/x86_64/libkmod.a \
    $(MKSDK)/Library/universal/libkmodc++.a \
    -F$(SDK)/System/Library/Frameworks

# ------------------------------------------------------------------ #
# Targets                                                             #
# ------------------------------------------------------------------ #

.PHONY: all kext ctl install load unload clean

all: kext ctl

kext: $(OUT_KEXT_BIN)

# Link, then assemble the full kext bundle in build/out/
$(OUT_KEXT_BIN): $(ALL_OBJS) | $(OUT_KEXT)/Contents/MacOS
	@echo "  LD   $(notdir $@)"
	$(LD) $(KEXT_LDFLAGS) -o $@ $(ALL_OBJS)
	@echo "  SYNC $(OUT_KEXT)"
	rsync -a --exclude='MacOS' $(KEXT_SKEL)/ $(OUT_KEXT)/
	@echo "  NOTE  run 'sudo chown -R root:wheel $(OUT_KEXT)' for kextutil"
	@echo "  KEXT $$(dwarfdump --uuid $(OUT_KEXT_BIN) 2>/dev/null)"
	@echo "  OK   build/out/rtw88.kext"

# Compile Linux driver C files with compat headers
$(BUILD_DIR)/driver/%.o: $(LINUX_SRC)/%.c | $(BUILD_DIR)/driver
	@echo "  CC   $(notdir $<)"
	$(CC) $(DRIVER_CFLAGS) -c $< -o $@

# Compile compat C files (with Linux compat headers)
$(BUILD_DIR)/compat/%.o: $(COMPAT_DIR)/%.c | $(BUILD_DIR)/compat
	@echo "  CC   $(notdir $<)"
	$(CC) $(DRIVER_CFLAGS) -c $< -o $@

# Generate fw_blobs.c from firmware/*.bin (zlib-compressed embedded blobs)
$(FW_BLOBS_C): $(wildcard $(FIRMWARE_DIR)/*.bin) scripts/gen_fw_blobs.py
	@echo "  GEN  fw_blobs.c"
	python3 $(PROJ_ROOT)/scripts/gen_fw_blobs.py $(FIRMWARE_DIR) $@

# Compile firmware loader + blobs (system headers only — no compat header conflicts)
FW_CFLAGS := $(KEXT_FLAGS) \
    -I$(MKSDK)/Headers \
    -I$(SDK)/System/Library/Frameworks/Kernel.framework/Headers \
    -I$(COMPAT_DIR) \
    -Wno-unused-function

$(BUILD_DIR)/compat/rtw88_firmware.o: $(COMPAT_DIR)/rtw88_firmware.c | $(BUILD_DIR)/compat
	@echo "  CC   rtw88_firmware.c"
	$(CC) $(FW_CFLAGS) -c $< -o $@

$(BUILD_DIR)/compat/fw_blobs.o: $(COMPAT_DIR)/fw_blobs.c | $(BUILD_DIR)/compat
	@echo "  CC   fw_blobs.c"
	$(CC) $(FW_CFLAGS) -c $< -o $@

# Compile kmod_info.c (plain C, no compat headers)
$(BUILD_DIR)/kext/kmod_info.o: $(KEXT_SRC)/kmod_info.c | $(BUILD_DIR)/kext
	@echo "  CC   kmod_info.c"
	$(CC) $(KEXT_FLAGS) -c $< -o $@

# Compile kext C++ wrapper files
$(BUILD_DIR)/kext/%.o: $(KEXT_SRC)/%.cpp | $(BUILD_DIR)/kext
	@echo "  CXX  $(notdir $<)"
	$(CXX) $(KEXT_CXXFLAGS) -c $< -o $@

# ctl binary
ctl: $(OUT_CTL)

$(OUT_CTL): $(CTL_DIR)/main.c | $(OUT_DIR)
	@echo "  CC   rtw88ctl"
	$(CC) $(ARCH) $(MINOS) \
	    -isysroot $(SDK) \
	    -framework IOKit \
	    -framework CoreFoundation \
	    -o $@ $<
	@echo "  OK   build/out/rtw88ctl"

# ------------------------------------------------------------------ #
# Directory creation                                                  #
# ------------------------------------------------------------------ #

$(BUILD_DIR)/driver:
	mkdir -p $@

$(BUILD_DIR)/compat:
	mkdir -p $@

$(BUILD_DIR)/kext:
	mkdir -p $@

$(OUT_DIR):
	mkdir -p $@

$(OUT_KEXT)/Contents/MacOS:
	mkdir -p $@

# ------------------------------------------------------------------ #
# Install / load                                                      #
# ------------------------------------------------------------------ #

install: kext ctl
	@echo "Installing rtw88.kext to /Library/Extensions..."
	sudo cp -R $(OUT_KEXT) /Library/Extensions/
	sudo chown -R root:wheel /Library/Extensions/rtw88.kext
	sudo chmod -R 755 /Library/Extensions/rtw88.kext
	@echo "Installing rtw88ctl to /usr/local/bin..."
	sudo install -m 755 $(OUT_CTL) /usr/local/bin/rtw88ctl
	@echo "Done. Run 'make load' or reboot to activate."

load:
	@echo "Loading rtw88.kext (requires SIP kext loading enabled)..."
	sudo kextutil -v $(OUT_KEXT)

unload:
	@echo "Unloading rtw88.kext..."
	sudo kextunload -b com.rtw88.driver

clean:
	rm -rf $(BUILD_DIR)

# ------------------------------------------------------------------ #
# OpenCore injection helper                                           #
# ------------------------------------------------------------------ #
# To use with OpenCore:
#   1. Copy build/out/rtw88.kext to OC/Kexts/
#   2. Add to config.plist -> Kernel -> Add:
#      Arch: Any
#      BundlePath: rtw88.kext
#      Comment: Realtek rtw88 WiFi
#      Enabled: YES
#      ExecutablePath: Contents/MacOS/rtw88
#      MaxKernel: (empty)
#      MinKernel: 20.0.0   (macOS 11+)
#      PlistPath: Contents/Info.plist
#   3. Rebuild OC cache: sudo kextcache -i /
#
# BaseSystem / Recovery notes:
#   The kext loads via OpenCore injection before the OS, so it works
#   in BaseSystem automatically.  rtw88ctl is a standalone binary;
#   copy it to the USB installer's /usr/local/bin or run from a path.
# RTL88WiFi native IO80211 target. Its controller and interface sources
# live in src/kext/:
#   RTL88WiFi.hpp  RTL88WiFi.cpp
#   RTL88WiFiInterface.hpp  RTL88WiFiInterface.cpp

AIRPORT_KEXT_SKEL := $(PROJ_ROOT)/RTL88WiFi.kext
AIRPORT_OUT_KEXT  := $(OUT_DIR)/RTL88WiFi.kext
AIRPORT_OUT_BIN   := $(AIRPORT_OUT_KEXT)/Contents/MacOS/RTL88WiFi

AIRPORT_KEXT_SRCS := \
    $(KEXT_SRC)/RTW88IEEE80211.cpp \
    $(KEXT_SRC)/RTW88HwOps.cpp \
    $(KEXT_SRC)/RTL88WiFi.cpp \
    $(KEXT_SRC)/RTL88WiFiAWDL.cpp \
    $(KEXT_SRC)/RTW88AWDLManager.cpp \
    $(KEXT_SRC)/RTL88WiFiInterface.cpp \
    $(KEXT_SRC)/RTW88WCLRadioBridge.cpp \
    $(KEXT_SRC)/RTW88WCLWorkQueue.cpp

AIRPORT_KEXT_OBJS := $(patsubst $(KEXT_SRC)/%.cpp, $(BUILD_DIR)/airport/%.o, $(AIRPORT_KEXT_SRCS))

# Compile-only Sequoia 24H32 controller ABI slice. This object is deliberately
# NOT linked into the legacy/bridge Kext: its IO80211Controller declaration has
# a different vtable ABI from the legacy header used by the active target.
WCL24H32_CONTROLLER_SRC := $(KEXT_SRC)/wcl24h32/RTW88WCLController.cpp
WCL24H32_CONTROLLER_OBJ := $(BUILD_DIR)/wcl24h32/RTW88WCLController.o
WCL24H32_INFRA_SRC := $(KEXT_SRC)/wcl24h32/RTW88WCLInfraInterface.cpp
WCL24H32_INFRA_OBJ := $(BUILD_DIR)/wcl24h32/RTW88WCLInfraInterface.o
WCL24H32_PCI_BACKEND_SRC := $(KEXT_SRC)/wcl24h32/RTW88WCLPCIBackend.cpp
WCL24H32_PCI_BACKEND_OBJ := $(BUILD_DIR)/wcl24h32/RTW88WCLPCIBackend.o
WCL24H32_SKYWALK_QUEUES_SRC := $(KEXT_SRC)/wcl24h32/RTW88WCLSkywalkQueues.cpp
WCL24H32_SKYWALK_QUEUES_OBJ := $(BUILD_DIR)/wcl24h32/RTW88WCLSkywalkQueues.o
WCL24H32_TX_ADAPTER_SRC := $(KEXT_SRC)/wcl24h32/RTW88WCLSkywalkTxAdapter.cpp
WCL24H32_TX_ADAPTER_OBJ := $(BUILD_DIR)/wcl24h32/RTW88WCLSkywalkTxAdapter.o
WCL24H32_RX_ADAPTER_SRC := $(KEXT_SRC)/wcl24h32/RTW88WCLSkywalkRxAdapter.cpp
WCL24H32_RX_ADAPTER_OBJ := $(BUILD_DIR)/wcl24h32/RTW88WCLSkywalkRxAdapter.o
WCL24H32_CXXFLAGS := $(KEXT_CXXFLAGS) -D__IO80211_TARGET=__MAC_15_2 -I$(KEXT_SRC)/wcl24h32

AIRPORT_KMOD_OBJ := $(BUILD_DIR)/airport/kmod_info.o

AIRPORT_ALL_OBJS := $(DRIVER_OBJS) $(CHIP_OBJS) $(COMPAT_OBJS) $(FIRMWARE_OBJS) $(AIRPORT_KMOD_OBJ) $(AIRPORT_KEXT_OBJS)

AIRPORT_LDFLAGS := \
    $(ARCH) -static -nostdlib -Xlinker -kext \
    $(MKSDK)/Library/x86_64/libkmod.a \
    -Xlinker -undefined -Xlinker dynamic_lookup

.PHONY: rtl88wifi rtl88wifi-wcl-controller-abi-check wcl-abi-audit-24h32
rtl88wifi: $(AIRPORT_OUT_BIN) rtl88wifi-wcl-controller-abi-check

# Emit complete 24H32 registration/deregistration function bodies and their
# Apple call paths directly to stdout. The user can append this report to the
# one project-root output.log after the normal build for focused ABI review.
ABI_ARCHIVE ?= $(HOME)/Downloads/RTL88WiFi-Sequoia-24H32-kcabi.tar.gz
wcl-abi-audit-24h32:
	@test -r "$(ABI_ARCHIVE)" || { echo "ERROR: ABI archive not readable: $(ABI_ARCHIVE)"; exit 2; }
	@echo "  WCL-ABI AUDIT  Sequoia 24H32 registration and call paths"
	python3 $(PROJ_ROOT)/../../tools/audit-skywalk-registration-24H32.py "$(ABI_ARCHIVE)" --full-registration-asm --stdout

# Compile the native Sequoia 24H32 controller/interface and ABI-neutral PCI
# owner independently. All objects stay out of AIRPORT_ALL_OBJS: the active
# Kext still includes the legacy IO80211Controller declaration and must not
# mix the incompatible ABI. The controller now owns the PCI backend and RTW88
# state-machine object in a staged, fail-closed lifecycle.
rtl88wifi-wcl-controller-abi-check: $(WCL24H32_CONTROLLER_OBJ) $(WCL24H32_INFRA_OBJ) $(WCL24H32_PCI_BACKEND_OBJ) $(WCL24H32_SKYWALK_QUEUES_OBJ) $(WCL24H32_TX_ADAPTER_OBJ) $(WCL24H32_RX_ADAPTER_OBJ)

$(WCL24H32_CONTROLLER_OBJ): $(WCL24H32_CONTROLLER_SRC) \
    $(KEXT_SRC)/wcl24h32/RTW88WCLController.hpp \
    $(KEXT_SRC)/wcl24h32/RTW88WCL24H32InterfaceABI.hpp \
    $(KEXT_SRC)/wcl24h32/RTW88WCLPCIBackend.hpp \
    $(KEXT_SRC)/wcl24h32/RTW88WCLSkywalkQueues.hpp \
    $(KEXT_SRC)/wcl24h32/RTW88WCLSkywalkTxAdapter.hpp \
    $(KEXT_SRC)/wcl24h32/RTW88WCLSkywalkRxAdapter.hpp \
    $(KEXT_SRC)/wcl24h32/RTW88WCLMbufRing.hpp \
    $(KEXT_SRC)/wcl24h32/RTW88WCL24H32ABI.hpp \
    $(KEXT_SRC)/RTW88IEEE80211.hpp \
    $(KEXT_SRC)/RTW88TxSequenceNumbers.hpp \
    | $(BUILD_DIR)/wcl24h32
	@echo "  WCL-ABI CXX  RTW88WCLController.cpp (24H32, bounded RX packet owner; compile-only)"
	$(CXX) $(WCL24H32_CXXFLAGS) -c $< -o $@

$(WCL24H32_INFRA_OBJ): $(WCL24H32_INFRA_SRC) \
    $(KEXT_SRC)/wcl24h32/RTW88WCLInfraInterface.hpp \
    $(KEXT_SRC)/wcl24h32/RTW88WCLRegistrationInfo.hpp \
    $(KEXT_SRC)/wcl24h32/RTW88WCLRequestDecoder.hpp \
    $(KEXT_SRC)/wcl24h32/RTW88WCL24H32InterfaceABI.hpp \
    $(KEXT_SRC)/wcl24h32/RTW88WCLController.hpp \
    $(KEXT_SRC)/RTW88WCLRadioBridge.hpp \
    $(KEXT_SRC)/RTW88WCLWorkQueue.hpp \
    | $(BUILD_DIR)/wcl24h32
	@echo "  WCL-ABI CXX  RTW88WCLInfraInterface.cpp (24H32, compile-only)"
	$(CXX) $(WCL24H32_CXXFLAGS) -c $< -o $@

$(WCL24H32_PCI_BACKEND_OBJ): $(WCL24H32_PCI_BACKEND_SRC) \
    $(KEXT_SRC)/wcl24h32/RTW88WCLPCIBackend.hpp \
    $(KEXT_SRC)/RTW88IEEE80211.hpp \
    $(KEXT_SRC)/RTW88TxSequenceNumbers.hpp \
    $(KEXT_SRC)/../compat/rtw88_compat.h \
    | $(BUILD_DIR)/wcl24h32
	@echo "  WCL-ABI CXX  RTW88WCLPCIBackend.cpp (ABI-neutral, compile-only)"
	$(CXX) $(WCL24H32_CXXFLAGS) -c $< -o $@

$(WCL24H32_SKYWALK_QUEUES_OBJ): $(WCL24H32_SKYWALK_QUEUES_SRC) \
    $(KEXT_SRC)/wcl24h32/RTW88WCLSkywalkQueues.hpp \
    $(KEXT_SRC)/wcl24h32/RTW88WCLSkywalkTxAdapter.hpp \
    $(KEXT_SRC)/wcl24h32/RTW88WCLTxSubmissionBatch.hpp \
    $(KEXT_SRC)/wcl24h32/RTW88WCLTxSubmissionGate.hpp \
    $(KEXT_SRC)/wcl24h32/RTW88WCLPacketView.hpp \
    $(KEXT_SRC)/wcl24h32/RTW88WCLPacketSpanValidation.hpp \
    $(MKSDK)/Headers/IOKit/skywalk/IOSkywalkFamily.h \
    | $(BUILD_DIR)/wcl24h32
	@echo "  WCL-ABI CXX  RTW88WCLSkywalkQueues.cpp (24H32, unregistered queues)"
	$(CXX) $(WCL24H32_CXXFLAGS) -c $< -o $@

$(WCL24H32_TX_ADAPTER_OBJ): $(WCL24H32_TX_ADAPTER_SRC) \
    $(KEXT_SRC)/wcl24h32/RTW88WCLSkywalkTxAdapter.hpp \
    $(KEXT_SRC)/wcl24h32/RTW88WCLTxCompletionSlots.hpp \
    $(KEXT_SRC)/wcl24h32/RTW88WCLTxSubmissionGate.hpp \
    $(KEXT_SRC)/wcl24h32/RTW88WCLPacketView.hpp \
    $(KEXT_SRC)/wcl24h32/RTW88WCLPacketSpanValidation.hpp \
    $(KEXT_SRC)/RTW88IEEE80211.hpp \
    $(KEXT_SRC)/RTW88TxSequenceNumbers.hpp \
    | $(BUILD_DIR)/wcl24h32
	@echo "  WCL-ABI CXX  RTW88WCLSkywalkTxAdapter.cpp (24H32, mbuf copy + deferred completion; compile-only)"
	$(CXX) $(WCL24H32_CXXFLAGS) -c $< -o $@


$(WCL24H32_RX_ADAPTER_OBJ): $(WCL24H32_RX_ADAPTER_SRC) \
    $(KEXT_SRC)/wcl24h32/RTW88WCLSkywalkRxAdapter.hpp \
    $(KEXT_SRC)/wcl24h32/RTW88WCLMbufRing.hpp \
    $(KEXT_SRC)/wcl24h32/RTW88WCLPacketSpanValidation.hpp \
    $(MKSDK)/Headers/IOKit/skywalk/IOSkywalkNetworkPacket.h \
    $(MKSDK)/Headers/IOKit/skywalk/IOSkywalkMemorySegment.h \
    | $(BUILD_DIR)/wcl24h32
	@echo "  WCL-ABI CXX  RTW88WCLSkywalkRxAdapter.cpp (24H32, pool-backed RX conversion; compile-only)"
	$(CXX) $(WCL24H32_CXXFLAGS) -c $< -o $@

# Stage29b: isolated native Sequoia target. The standard rtl88wifi target above
# remains the working legacy bundle; this target is explicitly opt-in and never
# links the legacy IO80211Controller/interface frontend objects.
NATIVE_KEXT_SKEL := $(BUILD_DIR)/native-skeleton/RTL88WiFiNative.kext
NATIVE_INFO_PLIST := $(NATIVE_KEXT_SKEL)/Contents/Info.plist
NATIVE_OUT_KEXT := $(OUT_DIR)/RTL88WiFiNative.kext
NATIVE_OUT_BIN := $(NATIVE_OUT_KEXT)/Contents/MacOS/RTL88WiFiNative
NATIVE_CORE_OBJ_DIR := $(BUILD_DIR)/native
NATIVE_PLIST_GENERATOR := $(PROJ_ROOT)/../../tools/generate-sequoia-native-plist.py
NATIVE_CORE_HEADERS := $(wildcard $(KEXT_SRC)/*.hpp) $(wildcard $(KEXT_SRC)/wcl24h32/*.hpp)
NATIVE_CORE_OBJS := $(addprefix $(NATIVE_CORE_OBJ_DIR)/,RTW88IEEE80211.o RTW88HwOps.o RTW88WCLRadioBridge.o RTW88WCLWorkQueue.o)
NATIVE_ALL_OBJS := $(DRIVER_OBJS) $(CHIP_OBJS) $(COMPAT_OBJS) $(FIRMWARE_OBJS) $(AIRPORT_KMOD_OBJ) $(NATIVE_CORE_OBJS) $(WCL24H32_CONTROLLER_OBJ) $(WCL24H32_INFRA_OBJ) $(WCL24H32_PCI_BACKEND_OBJ) $(WCL24H32_SKYWALK_QUEUES_OBJ) $(WCL24H32_TX_ADAPTER_OBJ) $(WCL24H32_RX_ADAPTER_OBJ)
NATIVE_LDFLAGS := $(AIRPORT_LDFLAGS)

.PHONY: rtl88wifi-native native-plist
rtl88wifi-native: $(NATIVE_OUT_BIN)

# Resolve exact native Apple framework versions on the target 24H32 Mac. This
# generated skeleton is kept under build/ and does not alter the legacy plist.
native-plist: $(NATIVE_INFO_PLIST)

$(BUILD_DIR)/native-skeleton:
	mkdir -p $@

$(NATIVE_INFO_PLIST): $(PROJ_ROOT)/RTL88WiFi.kext/Contents/Info.plist \
    $(KEXT_SRC)/wcl24h32/RTW88WCLController.hpp \
    $(NATIVE_PLIST_GENERATOR) | $(BUILD_DIR)/native-skeleton
	@echo "  NATIVE PLIST  RTL88WiFiNative.kext (macOS 15.8.1 / 24H32)"
	python3 $(NATIVE_PLIST_GENERATOR) --base-plist "$<" \
	    --controller-header "$(KEXT_SRC)/wcl24h32/RTW88WCLController.hpp" \
	    --output "$@"

$(NATIVE_CORE_OBJ_DIR):
	mkdir -p $@

$(NATIVE_CORE_OBJ_DIR)/%.o: $(KEXT_SRC)/%.cpp $(NATIVE_CORE_HEADERS) | $(NATIVE_CORE_OBJ_DIR)
	@echo "  NATIVE CXX  $< (24H32 isolated RTW88 core object)"
	$(CXX) $(WCL24H32_CXXFLAGS) -c $< -o $@

$(NATIVE_OUT_KEXT)/Contents/MacOS:
	mkdir -p $@

$(NATIVE_OUT_BIN): $(NATIVE_ALL_OBJS) $(NATIVE_INFO_PLIST) | $(NATIVE_OUT_KEXT)/Contents/MacOS
	@echo "  NATIVE LD   $(notdir $@)"
	$(LD) $(NATIVE_LDFLAGS) -o $@ $(NATIVE_ALL_OBJS)
	@echo "  NATIVE SYNC $(NATIVE_OUT_KEXT)"
	rsync -a --exclude='MacOS' $(NATIVE_KEXT_SKEL)/ $(NATIVE_OUT_KEXT)/
	@echo "  NATIVE OK   $(NATIVE_OUT_KEXT)"

$(BUILD_DIR)/wcl24h32:
	mkdir -p $@

$(AIRPORT_OUT_BIN): $(AIRPORT_ALL_OBJS) $(AIRPORT_KEXT_SKEL)/Contents/Info.plist | $(AIRPORT_OUT_KEXT)/Contents/MacOS
	@echo "  LD   $(notdir $@)"
	$(LD) $(AIRPORT_LDFLAGS) -o $@ $(AIRPORT_ALL_OBJS)
	@echo "  SYNC $(AIRPORT_OUT_KEXT)"
	rsync -a --exclude='MacOS' $(AIRPORT_KEXT_SKEL)/ $(AIRPORT_OUT_KEXT)/
	@echo "  OK   build/out/RTL88WiFi.kext"

$(BUILD_DIR)/airport/%.o: $(KEXT_SRC)/%.cpp | $(BUILD_DIR)/airport
	@echo "  CXX  $(notdir $<)"
	$(CXX) $(KEXT_CXXFLAGS) -D__IO80211_TARGET=__MAC_13_0 -DUSE_APPLE_SUPPLICANT=1 -D__PRIVATE_SPI__ -c $< -o $@

$(AIRPORT_KMOD_OBJ): $(KEXT_SRC)/kmod_info.c | $(BUILD_DIR)/airport
	@echo "  CC   airport/kmod_info.c"
	$(CC) $(KEXT_FLAGS) -DRTW88_AIRPORT_KMOD=1 -c $< -o $@

$(BUILD_DIR)/airport:
	mkdir -p $@

$(AIRPORT_OUT_KEXT)/Contents/MacOS:
	mkdir -p $@

# Rebuild objects when one of their headers changes.
DEPFILES = $(ALL_OBJS:.o=.d) $(AIRPORT_KEXT_OBJS:.o=.d) $(AIRPORT_KMOD_OBJ:.o=.d) \
           $(WCL24H32_CONTROLLER_OBJ:.o=.d) $(WCL24H32_INFRA_OBJ:.o=.d) \
           $(WCL24H32_PCI_BACKEND_OBJ:.o=.d) $(WCL24H32_SKYWALK_QUEUES_OBJ:.o=.d) \
           $(WCL24H32_TX_ADAPTER_OBJ:.o=.d) $(WCL24H32_RX_ADAPTER_OBJ:.o=.d)
-include $(DEPFILES)

# Compiler flags and ABI macros in this file affect every object.
$(ALL_OBJS) $(AIRPORT_ALL_OBJS): Makefile
