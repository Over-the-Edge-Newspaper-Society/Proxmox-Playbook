#!/usr/bin/env bash
set -Eeuo pipefail
# Report saved-browser workers that still run an older browser runtime than the
# backend's BROWSER_RUNTIME_IMAGE. A worker keeps the image it was created with,
# so after a deploy that changes the runtime, a saved browser would otherwise
# stay on the old one: on 2026-11-21 the BC Bid download browser ran a runtime
# without cookie clearing for about a day.
#
# Zoer (fix/bcbid-download-failure-restart) moves a stopped, agent-controlled
# saved browser to the current runtime the next time it starts. Use Refresh
# runtime on a browser you need moved sooner. Read-only: changes nothing.
#
#   ./scripts/zoer-browser-runtime-check.sh        # uses $KUBECONFIG, namespace zoer
#   ZOER_NAMESPACE=other ./scripts/zoer-browser-runtime-check.sh
NS="${ZOER_NAMESPACE:-zoer}"

want="$(kubectl -n "$NS" get deploy zoer-backend \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="BROWSER_RUNTIME_IMAGE")].value}' 2>/dev/null || true)"
if [[ -z "$want" ]]; then
  echo "browser runtime check: zoer-backend has no BROWSER_RUNTIME_IMAGE; nothing to compare."
  exit 0
fi

stale=0 total=0
while read -r pod image; do
  [[ -n "$pod" ]] || continue
  total=$((total + 1))
  if [[ "$image" != "$want" ]]; then
    stale=$((stale + 1))
    echo "  older runtime: $pod runs ${image##*:} (current ${want##*:})"
  fi
done < <(kubectl -n "$NS" get pods -l zoer.browser-worker=true \
  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.containers[0].image}{"\n"}{end}' 2>/dev/null || true)

if (( stale )); then
  echo "browser runtime check: $stale of $total browser worker(s) on an older runtime; their saved browsers move to ${want##*:} the next time they start (or use Refresh runtime)."
else
  echo "browser runtime check: all $total browser worker(s) run ${want##*:}."
fi
