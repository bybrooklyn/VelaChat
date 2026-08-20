# VelaChat — task runner
set shell := ["bash", "-c"]

default: build

build:
    swift build

check:
    swift build

build-release:
    swift build -c release

run:
    swift run VelaChat

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
