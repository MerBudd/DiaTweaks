CFLAGS := -arch arm64 -mmacosx-version-min=14.0 -fobjc-arc -O2 -Wall -Wextra -Wno-unused-parameter
DYLIB_SOURCES := $(shell find src/dylib -name '*.[hm]')
DYLIB_SWIFT := $(shell find src/dylib -name '*.swift')
SDK := $(shell xcrun --show-sdk-path)
SWIFT_LIB := $(SDK)/usr/lib/swift
# FoundationModels only exists on macOS 26+, so it's weak-linked and Swift's automatic link to it is turned off. An
# older SDK has no FoundationModels at all; Tidy Tabs then builds without it and says so when used.
FOUNDATION_MODELS := $(if $(wildcard $(SDK)/System/Library/Frameworks/FoundationModels.framework),-weak_framework FoundationModels)
SWIFTFLAGS := -target arm64-apple-macos14.0 -O -parse-as-library -wmo -module-name DiaPatchesSwift \
	-Xfrontend -disable-autolink-framework -Xfrontend FoundationModels
PASSKEYS := src/dylib/Patches/Passkeys/extension
EXTENSION := $(foreach file,manifest.json page.js bridge.js worker.js,-Wl,-sectcreate,__TEXT,__pk_$(basename $(file)),$(PASSKEYS)/$(file))

# diapatch records the commit it was built from, to tell a source build that is newer than the latest release from one that isn't.
COMMIT := $(shell git rev-parse HEAD 2>/dev/null)

all: build/diapatch build/DiaPatches.dylib build/patches.json

build/commit: FORCE | build
	@echo '$(COMMIT)' | cmp -s - $@ || echo '$(COMMIT)' > $@

FORCE:

build/diapatch: $(wildcard src/diapatch/*.[hm]) build/commit | build
	clang $(CFLAGS) -DDIATWEAKS_COMMIT='"$(COMMIT)"' -framework AppKit -framework CoreGraphics -framework Security -o $@ $(filter %.m,$^)

build/DiaPatchesSwift.o: $(DYLIB_SWIFT) | build
	swiftc $(SWIFTFLAGS) -emit-object -o $@ $^

build/DiaPatches.dylib: $(DYLIB_SOURCES) build/DiaPatchesSwift.o $(wildcard $(PASSKEYS)/*) | build
	clang $(CFLAGS) -Isrc/dylib -dynamiclib $(EXTENSION) -framework AppKit -framework QuartzCore -framework Metal -framework AVFoundation -framework VideoToolbox -framework CoreMedia -framework CoreVideo \
		-L$(SWIFT_LIB) -Wl,-rpath,/usr/lib/swift $(FOUNDATION_MODELS) -o $@ $(filter %.m %.o,$^)

# The patch list for diatweaks. With DIAPATCH_MANIFEST set, the dylib writes it and exits as it loads, so diapatch never runs.
build/patches.json: build/DiaPatches.dylib build/diapatch
	DIAPATCH_MANIFEST=$@ DYLD_INSERT_LIBRARIES=$< build/diapatch

build:
	mkdir -p $@

GROUP_TABS := $(addprefix src/dylib/Commands/GroupTabs/,Plan.m Title.m Registrable.m Messages.m)

build/group-tabs: tests/group-tabs.m $(GROUP_TABS) | build
	clang $(CFLAGS) -Isrc/dylib -framework AppKit -o $@ $^

build/mouse-back-forward: tests/mouse-back-forward.m src/dylib/Patches/MouseBackForward/MouseBackForward.m src/dylib/StdPatch/Hook.m $(wildcard src/dylib/StdPatch/*.h) | build
	clang $(CFLAGS) -Isrc/dylib -framework AppKit -o $@ tests/mouse-back-forward.m src/dylib/StdPatch/Hook.m

build/vertical-tab-glow: tests/vertical-tab-glow.m $(wildcard src/dylib/Patches/HideVerticalTabGlow/*.[hm]) | build
	clang $(CFLAGS) -Isrc/dylib -framework AppKit -framework QuartzCore -o $@ $<

# Checks that need no Dia: grouping, the DiaTweaks update decision, mouse navigation, Hide Vertical Tab Glow, the Sidebar Grain textures, and that Settings shows each tweak like its neighbours.
check: build/diapatch build/group-tabs build/mouse-back-forward build/vertical-tab-glow build/patches.json
	tests/tweaks-update
	build/group-tabs
	build/mouse-back-forward
	build/vertical-tab-glow
	tests/sidebar-grain
	scripts/check-patches

test: build/DiaPatches.dylib
	./test.sh

# make patch NAME=HideFooButton starts a new patch in src/dylib/Patches/HideFooButton.
patch:
	@scripts/new-patch "$(NAME)"

clean:
	rm -rf build

.PHONY: all check clean test patch
