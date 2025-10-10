#!/usr/bin/env bash
set -euo pipefail
rm -rf dist build && mkdir -p build/python
pip install -r requirements.txt -t build/python
cd build && zip -r ../dist/python.zip python
