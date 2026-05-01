#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

python3.12 -m venv venv
source venv/bin/activate

pip install --upgrade pip
pip install -r timemachine-video-export/requirements.txt
pip install ./timemachine-video-export

echo "venv ready. activate with: source venv/bin/activate"
