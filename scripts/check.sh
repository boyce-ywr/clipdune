#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift run ClipDuneChecks
swift build -c release --product ClipDune
bash -n scripts/build.sh scripts/check-ui.sh scripts/check.sh
plutil -lint Resources/Info.plist
git diff --check
