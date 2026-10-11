#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 tools/make-test-clip.py
xcrun clang -std=c99 -Wall -Wextra -Werror -fsanitize=address,undefined -g -Ireceiver \
  receiver/ODWire.c tests/wire_test.c -o build/wire_test
build/wire_test build/selftest.h264
python3 -m py_compile tools/*.py
