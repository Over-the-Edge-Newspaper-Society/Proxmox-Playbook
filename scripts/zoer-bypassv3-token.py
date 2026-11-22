#!/usr/bin/env python3
"""Thin entrypoint for the vendored BypassV3 CLI.

Scope: Zoer-owned apps or systems you are explicitly authorized to test. See
scripts/bypassv3/NOTICE.md for the upstream commit and license, and
docs/ZOER-BYPASSV3.md for usage.

    ./scripts/zoer-bypassv3-token.py --site-key <KEY> --origin https://app.k8s.ote --action login
    ./scripts/zoer-bypassv3-token.py --anchor-url 'https://www.google.com/recaptcha/api2/anchor?...'
"""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))

from bypassv3.cli import main

if __name__ == "__main__":
    sys.exit(main())
