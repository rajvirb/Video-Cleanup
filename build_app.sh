#!/bin/bash
# Builds "dist/Sift.app" for this Mac, plus a zip of it to share.
# Needs uv: https://docs.astral.sh/uv/  (brew install uv)
set -euo pipefail
cd "$(dirname "$0")"

uv venv --quiet --allow-existing --python 3.12 .build/venv
uv pip install --quiet --python .build/venv -r requirements-app.txt
.build/venv/bin/pyinstaller --noconfirm --clean --log-level WARN \
    --distpath dist --workpath .build/work sift.spec

echo "Checking the app works…"
"dist/Sift.app/Contents/MacOS/Sift" --self-test

rm -f "dist/Sift.zip"
ditto -c -k --keepParent "dist/Sift.app" "dist/Sift.zip"
echo
echo "Built: dist/Sift.app"
echo "To share: dist/Sift.zip"
