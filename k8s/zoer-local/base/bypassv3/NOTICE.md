# In-cluster BypassV3 service

`bypass.py` in this directory is a verbatim copy of the vendored library at
[`scripts/bypassv3/bypass.py`](../../../../scripts/bypassv3/bypass.py). Kustomize
loads files relative to this base directory, so the library is copied here
rather than referenced out-of-tree. The copies must match byte for byte — see
[`tests/test_zoer_bypassv3_token.py`](../../../../tests/test_zoer_bypassv3_token.py)
for the consistency test.

License and full attribution live beside the canonical copy at
[`scripts/bypassv3/`](../../../../scripts/bypassv3/): LICENSE (Apache-2.0),
NOTICE.md (upstream URL, pinned commit, update recipe).

When updating the vendored library, update both copies in the same commit.
