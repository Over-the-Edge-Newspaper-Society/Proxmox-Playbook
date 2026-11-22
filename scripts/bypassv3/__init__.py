"""Vendored BypassV3 (Apache-2.0) for authorized Zoer-backend reCAPTCHA v3 testing.

Source: https://github.com/EvickaStudio/BypassV3
Pinned upstream commit: f470220d3e8d75302d4384b6487de7696b35372c
See LICENSE and NOTICE.md in this directory.

Scope: use only against Zoer-owned apps or systems you are explicitly authorized
to test. Submitting generated tokens to a third party whose bot protection you
do not own is outside the vendored library's upstream scope and is not what this
copy is here for.
"""

from .bypass import ReCaptchaV3Bypass

__all__ = ["ReCaptchaV3Bypass"]
