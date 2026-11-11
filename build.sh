#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"
export LC_ALL=C
umask 022
usage() {
    echo "Usage: ./build.sh [--fingerprint SHA256 [--certificate FILE]]" >&2
    exit 2
}

pin=
certificate=
if [[ $# -gt 0 ]]; then
    [[ $# == 2 || $# == 4 ]] || usage
    [[ $1 == --fingerprint ]] || usage
    pin=$(printf '%s' "$2" | tr -d ':' | tr 'A-F' 'a-f')
    [[ $pin =~ ^[0-9a-f]{64}$ ]] || usage
    if [[ $# == 4 ]]; then
        [[ $3 == --certificate ]] || usage
        certificate=$4
    fi
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
stage="$work/stage"
app="$stage/Royal GTPS Setup.app"
mkdir -p "$app/Contents/"{MacOS,Helpers,Resources}
printf 'enum BuildPin { static let sha256 = "%s" }\n' "$pin" > "$work/BuildPin.swift"
if [[ -n $pin ]]; then
    if [[ -z $certificate ]]; then
        certificate="$work/download.crt"
        /usr/bin/curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
            --max-time 60 --output "$certificate" 'https://gtps.link/downloads/gtps-hosts-ca.crt?v=7318563622b6'
    fi
    xcrun swiftc -swift-version 5 Sources/Hosts.swift Sources/Certificate.swift Sources/CheckCertificate.swift \
        "$work/BuildPin.swift" -o "$work/check-certificate"
    "$work/check-certificate" "$certificate" "$app/Contents/Resources/RoyalGTPS.crt"
fi
cp Sources/Info.plist "$app/Contents/Info.plist"
cp Sources/SetupWindow.html Sources/RoyalBanner.png "$app/Contents/Resources/"
cp 'Player Instructions.txt' "$stage/"

sdk=$(xcrun --sdk macosx --show-sdk-path)
for arch in arm64 x86_64; do
    xcrun swiftc -swift-version 5 -target "${arch}-apple-macos13.0" -sdk "$sdk" -O \
        Sources/Hosts.swift Sources/Certificate.swift Sources/App.swift "$work/BuildPin.swift" -o "$work/app-$arch"
    xcrun swiftc -swift-version 5 -target "${arch}-apple-macos13.0" -sdk "$sdk" -O \
        Sources/Hosts.swift Sources/Certificate.swift Sources/Installer.swift "$work/BuildPin.swift" -o "$work/helper-$arch"
done
xcrun lipo -create "$work/app-arm64" "$work/app-x86_64" -output "$app/Contents/MacOS/RoyalGTPSSetup"
xcrun lipo -create "$work/helper-arm64" "$work/helper-x86_64" -output "$app/Contents/Helpers/RoyalGTPSHelper"
chmod 755 "$app/Contents/MacOS/RoyalGTPSSetup" "$app/Contents/Helpers/RoyalGTPSHelper"
/usr/bin/codesign --force --sign - "$app/Contents/Helpers/RoyalGTPSHelper"
/usr/bin/codesign --force --sign - "$app"
/usr/bin/codesign --verify --deep --strict "$app"
mkdir -p dist
/usr/bin/ditto -c -k --norsrc "$stage" "$work/Royal GTPS Setup.zip"
mv -f "$work/Royal GTPS Setup.zip" 'dist/Royal GTPS Setup.zip'
printf 'Built %s\n' 'dist/Royal GTPS Setup.zip'
