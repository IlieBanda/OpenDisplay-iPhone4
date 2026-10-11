#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .deps
archive=.deps/iPhoneOS6.1.sdk.zip
expected=2696df17fc48e1b6ea3f7acd346b5f2356fb5c6cc60b0f3aaca0c24522d761de
if [[ ! -f "$archive" ]]; then
  curl -fL --retry 2 https://github.com/growtopiajaw/iPhoneOS-SDK/releases/download/v1.0/iPhoneOS6.1.sdk.zip -o "$archive"
fi
actual="$(shasum -a 256 "$archive" | cut -d ' ' -f 1)"
[[ "$actual" == "$expected" ]] || { echo 'SDK checksum mismatch.' >&2; exit 1; }
[[ -d .deps/iPhoneOS6.1.sdk ]] || unzip -q "$archive" -d .deps
echo 'iOS 6.1 SDK ready in .deps/'
