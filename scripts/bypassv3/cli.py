"""CLI that prints a reCAPTCHA v3 token from the vendored BypassV3 library.

Scope: Zoer-owned apps or systems you are explicitly authorized to test. The
token is intended for submission to your own backend's reCAPTCHA v3 verifier,
not to third-party sites whose bot protection you do not own.
"""
import argparse
import sys

from .bypass import ReCaptchaV3Bypass


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="zoer-bypassv3-token",
        description=(
            "Generate a reCAPTCHA v3 token for an authorized Zoer-owned test app."
        ),
    )
    group = p.add_mutually_exclusive_group(required=True)
    group.add_argument("--site-key", help="reCAPTCHA site key; requires --origin.")
    group.add_argument(
        "--anchor-url",
        help="Full reCAPTCHA anchor URL (captured from the browser's network tab).",
    )
    p.add_argument(
        "--origin",
        help="Scheme://host[:port] of the test app page, required with --site-key.",
    )
    p.add_argument("--action", help="reCAPTCHA v3 action bound into the token.")
    p.add_argument(
        "--enterprise",
        action="store_true",
        help="Resolve against the reCAPTCHA Enterprise endpoint.",
    )
    p.add_argument(
        "--max-retries",
        type=int,
        default=3,
        help="How many anchor/reload attempts before giving up (default: 3).",
    )
    return p


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    if args.site_key:
        if not args.origin:
            parser.error("--origin is required when --site-key is used.")
        instance = ReCaptchaV3Bypass.from_site_key(
            args.site_key,
            args.origin,
            action=args.action,
            enterprise=args.enterprise,
            max_retries=args.max_retries,
        )
    else:
        instance = ReCaptchaV3Bypass(
            args.anchor_url,
            action=args.action,
            max_retries=args.max_retries,
        )

    token = instance.bypass()
    if not token:
        print("zoer-bypassv3-token: no token returned.", file=sys.stderr)
        return 1
    print(token)
    return 0


if __name__ == "__main__":
    sys.exit(main())
