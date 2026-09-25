# VelaChat — task runner
set shell := ["bash", "-c"]

# CLT-only machines (no Xcode) ship no SwiftUIMacros plugin for the
# current SDK, so every SwiftUI file fails to compile there. The macOS
# 26.5 CLT SDK still declares @State et al. without macros — use it when
# present and Xcode isn't. Full-Xcode machines (CI) use their default.
sdk_flag := `if [ -d "/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk" ] && [ ! -d "/Applications/Xcode.app" ]; then echo "--sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"; fi`

default: build

build:
    swift build {{sdk_flag}}

check:
    swift build {{sdk_flag}}

build-release:
    swift build -c release {{sdk_flag}}

run:
    swift run VelaChat {{sdk_flag}}

setup-signing:
    ./Scripts/setup-signing.sh

# Regenerate the dock icon from Scripts/make-icon.swift. Committed output
# (Resources/VelaChat.icns) so CI never has to rasterize an SF Symbol.
icon:
    swift Scripts/make-icon.swift build/AppIcon.iconset
    iconutil -c icns build/AppIcon.iconset -o Resources/VelaChat.icns
    @echo "✅ Resources/VelaChat.icns updated — commit it."

app:
    ./Scripts/build-app.sh --release

open-app:
    open "build/VelaChat.app"

clean:
    rm -rf .build build

smoke:
    just app
    open "build/VelaChat.app"
