#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
sdk="${OD_IOS_SDK:-$PWD/.deps/iPhoneOS6.1.sdk}"
if [[ ! -d "$sdk" ]]; then
  echo "Missing iOS 6.1 SDK: $sdk. See README.md." >&2
  exit 1
fi
command -v ldid >/dev/null || { echo "ldid is required for the jailbreak build." >&2; exit 1; }
[[ -f resources/selftest.odframes ]] || python3 tools/make-test-clip.py
app="$PWD/build/Payload/OpenDisplay4.app"
mkdir -p "$app" build/objects
for file in receiver/*.m receiver/*.c; do
  name="$(basename "${file%.*}")"
  # Recent ld loses Thumb bits in LC_MAIN and Objective-C IMP relocations
  # for this old target. ARM mode avoids both on the real A4/iOS 6 device.
  mode=-marm
  xcrun clang -target armv7-apple-ios6.0 -isysroot "$sdk" \
    "$mode" \
    -fobjc-arc -fblocks -DOS_OBJECT_USE_OBJC=0 -Os -g -Wall -Wextra \
    -Wno-unused-parameter -Wno-deprecated-declarations -Ireceiver \
    -c "$file" -o "build/objects/$name.o"
done
xcrun clang -target armv7-apple-ios6.0 -isysroot "$sdk" \
  -Wl,-no_fixup_chains -Wl,-no_adhoc_codesign \
  build/objects/*.o -framework UIKit -framework Foundation -framework CoreFoundation \
  -framework CoreMedia -framework CoreVideo -framework CoreGraphics -framework QuartzCore -framework GLKit \
  -framework OpenGLES -o "$app/OpenDisplay4"
cp resources/Info.plist resources/selftest.odframes "$app/"
cp resources/LegacyIcon*.png "$app/"
ldid -Sresources/Entitlements.plist "$app/OpenDisplay4"
python3 tools/package.py
file "$app/OpenDisplay4"
echo "Built build/OpenDisplay4.ipa and build/OpenDisplay4-device.tar.gz"
