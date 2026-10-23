#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift run ClipDuneChecks
swift build -c release --product ClipDune
swift build -c release --product ClipDuneUpdateHelper
swift build --product ClipDuneReleaseTool
bash -n scripts/build.sh scripts/check-ui.sh scripts/check.sh scripts/check-dmg.sh scripts/release.sh
plutil -lint Resources/Info.plist
git diff --check
