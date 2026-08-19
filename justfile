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

app:
    ./Scripts/build-app.sh --release

open-app:
    open "build/VelaChat.app"

clean:
    rm -rf .build build

smoke:
    just app
    open "build/VelaChat.app"
