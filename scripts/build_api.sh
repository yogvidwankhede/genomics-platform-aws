#!/usr/bin/env bash
# Build build/api.zip for the arm64 python3.13 Lambda runtime (manylinux wheels only, no sdists).
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=build/api
mkdir -p build
[[ -d "$OUT" ]] && find "$OUT" -mindepth 1 -delete
mkdir -p "$OUT"
"${PYTHON:-python3}" -m pip install --quiet --disable-pip-version-check \
  --platform manylinux2014_aarch64 --implementation cp --python-version 3.13 --only-binary=:all: \
  --target "$OUT" fastapi==0.165.0 mangum==0.22.0 pydantic==2.14.4
cp -R services/api/src/gp_api "$OUT/"
find "$OUT" -name '__pycache__' -type d -prune -exec rm -r {} +
( cd "$OUT" && python3 -c "
import os, zipfile
with zipfile.ZipFile('../api.zip', 'w', zipfile.ZIP_DEFLATED) as z:
    for root, _, files in os.walk('.'):
        for f in sorted(files):
            p = os.path.join(root, f)
            info = zipfile.ZipInfo(os.path.relpath(p, '.'), date_time=(2026, 1, 1, 0, 0, 0))
            info.external_attr = 0o644 << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            z.writestr(info, open(p, 'rb').read())
" )
ls -la build/api.zip
