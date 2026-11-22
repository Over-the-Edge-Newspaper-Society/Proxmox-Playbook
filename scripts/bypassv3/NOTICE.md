# BypassV3 — vendored

**Upstream:** https://github.com/EvickaStudio/BypassV3
**License:** Apache License 2.0 (see `LICENSE` in this directory)
**Pinned commit:** `f470220d3e8d75302d4384b6487de7696b35372c` (upstream `main` at 2026-11-11)
**Vendored file:** `bypass.py` is copied verbatim from the pinned commit; no modifications.

## Attribution

Copyright 2026 EvickaStudio. Distributed under the Apache License, Version 2.0.
You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0.

## Scope reminder from upstream

Upstream README: "the toolkit should be used only on applications you own or are
authorized to test." This vendored copy is included for authorized testing of
Zoer-owned backends' reCAPTCHA v3 verification only. It is not for use against
third-party sites' bot protection.

## Updating

To refresh this vendored copy against a newer upstream commit:

1. Pick the new upstream commit SHA.
2. Replace `bypass.py` with the file at
   `https://raw.githubusercontent.com/EvickaStudio/BypassV3/<SHA>/bypass.py`.
3. Update the "Pinned commit" line above with the new SHA.
4. Run `python3 -m unittest tests.test_zoer_bypassv3_token` from the repo root.
