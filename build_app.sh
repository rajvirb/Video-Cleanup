#!/bin/bash
# Builds "dist/Video Cleanup.app" for this Mac, plus a zip of it to share.
# Needs uv: https://docs.astral.sh/uv/  (brew install uv)
set -euo pipefail
cd "$(dirname "$0")"

uv venv --quiet --allow-existing --python 3.12 .build/venv
uv pip install --quiet --python .build/venv -r requirements-app.txt
.build/venv/bin/pyinstaller --noconfirm --clean --log-level WARN \
    --distpath dist --workpath .build/work video_cleanup.spec

echo "Checking the app works…"
"dist/Video Cleanup.app/Contents/MacOS/Video Cleanup" --self-test

rm -f "dist/Video Cleanup.zip"
ditto -c -k --keepParent "dist/Video Cleanup.app" "dist/Video Cleanup.zip"
echo
echo "Built: dist/Video Cleanup.app"
echo "To share: dist/Video Cleanup.zip"
