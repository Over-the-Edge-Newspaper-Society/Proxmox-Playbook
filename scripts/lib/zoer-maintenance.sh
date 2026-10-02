# shellcheck shell=bash
# Maintenance drain helpers for scripts/zoer-deploy.sh (sourced, not executed).
#
# The backend exposes a loopback-only API under /api/internal/maintenance:
#   POST /drain   -> stop claiming work, pause what can be paused
#   GET  /        -> { draining, drainId, active[], paused[], blocking[], safeToRestart }
#   POST /resume  -> clear the drain and re-queue the paused steps
#
# By default every call runs `bun -e fetch(...)` inside the backend container
# via `kubectl exec` (the image has bun but no curl/wget). Set
# ZOER_MAINTENANCE_URL (backend origin, e.g. http://127.0.0.1:4000) and
# optionally ZOER_MAINTENANCE_TOKEN to call it with local curl instead - used by
# tests/test_zoer_maintenance.py; the plugin-runner pod check is skipped then.
#
# Requires jq locally to read the status JSON.

ZM_NS="${ZM_NS:-${ZOER_NAMESPACE:-zoer}}"
ZM_DEPLOY="${ZM_DEPLOY:-zoer-backend}"
ZM_CONTAINER="${ZM_CONTAINER:-backend}"
ZM_POLL_SECONDS="${ZOER_DRAIN_POLL_SECONDS:-5}"
ZM_HEARTBEAT_SECONDS="${ZOER_DRAIN_HEARTBEAT_SECONDS:-30}"
# How long the EXIT trap waits for some backend pod to answer before giving up.
ZM_TRAP_WAIT="${ZOER_RESUME_TRAP_WAIT:-180}"
if [[ -n "${ZOER_MAINTENANCE_URL:-}" ]]; then ZM_PLUGIN_POD_CHECK="${ZM_PLUGIN_POD_CHECK:-0}"; else ZM_PLUGIN_POD_CHECK="${ZM_PLUGIN_POD_CHECK:-1}"; fi

ZM_DRAINED=0     # 1 once a drain was requested; the EXIT trap then resumes
ZM_RESUMED=0     # 1 once resume was confirmed
ZM_DRAIN_ID=""
ZM_TARGET=""     # pod name for kubectl exec; empty = deploy/$ZM_DEPLOY
ZM_STATUS="000"  # HTTP status of the last call (000 = transport failure)
ZM_BODY=""       # response body of the last call

# Runs inside the backend container. argv: METHOD SUFFIX BODY. Prints the body,
# a newline, then the HTTP status (000 when the request itself failed).
# shellcheck disable=SC2016
ZM_BUN_CLIENT='const [method, suffix, body] = process.argv.slice(-3);
const url = "http://127.0.0.1:" + (process.env.PORT || 4000) + "/api/internal/maintenance" + suffix;
const headers = {};
if (body) headers["content-type"] = "application/json";
if (process.env.ZOER_MAINTENANCE_TOKEN) headers.authorization = "Bearer " + process.env.ZOER_MAINTENANCE_TOKEN;
try {
  const r = await fetch(url, { method, headers, body: body || undefined, signal: AbortSignal.timeout(20000) });
  process.stdout.write((await r.text()) + "\n" + r.status);
} catch (e) { console.error(String(e)); process.stdout.write("\n000"); }'

# zm_request METHOD SUFFIX [BODY] -> sets ZM_STATUS and ZM_BODY; never fails.
zm_request() {
  local method="$1" suffix="$2" body="${3:-}" out=""
  if [[ -n "${ZOER_MAINTENANCE_URL:-}" ]]; then
    local base="${ZOER_MAINTENANCE_URL%/}"
    [[ "$base" == */api/internal/maintenance ]] || base="$base/api/internal/maintenance"
    local args=(-sS --max-time 20 -X "$method" -w $'\n%{http_code}')
    [[ -n "${ZOER_MAINTENANCE_TOKEN:-}" ]] && args+=(-H "authorization: Bearer $ZOER_MAINTENANCE_TOKEN")
    [[ -n "$body" ]] && args+=(-H 'content-type: application/json' --data "$body")
    out="$(curl "${args[@]}" "$base$suffix" 2>/dev/null)" || true
  else
    out="$(kubectl -n "$ZM_NS" --request-timeout=40s exec "${ZM_TARGET:-deploy/$ZM_DEPLOY}" -c "$ZM_CONTAINER" -- \
             bun -e "$ZM_BUN_CLIENT" "$method" "$suffix" "$body" 2>/dev/null)" || true
  fi
  ZM_STATUS="${out##*$'\n'}"
  [[ "$ZM_STATUS" =~ ^[0-9]{3}$ ]] || ZM_STATUS="000"
  if [[ "$out" == *$'\n'* ]]; then ZM_BODY="${out%$'\n'*}"; else ZM_BODY=""; fi
}

zm_json() { jq -r "$1" <<<"$ZM_BODY" 2>/dev/null; }

# Backend pods, newest first. zm_pods live|terminating
zm_pods() {
  local want="$1"
  kubectl -n "$ZM_NS" --request-timeout=20s get pods -l "app=$ZM_DEPLOY" \
    -o jsonpath='{range .items[*]}{.metadata.creationTimestamp}{" "}{.metadata.name}{" "}{.metadata.deletionTimestamp}{"\n"}{end}' 2>/dev/null \
    | sort -r | awk -v want="$want" '(want == "live" && NF == 2) || (want == "terminating" && NF == 3) { print $2 }'
}

# Plugin-runner worker pods that have not finished.
zm_plugin_pods() {
  kubectl -n "$ZM_NS" --request-timeout=20s get pods -l zoer.plugin-runner=true \
    --field-selector=status.phase!=Succeeded,status.phase!=Failed -o name 2>/dev/null || true
}

# zm_probe -> 0 endpoint present (ZM_BODY holds the status), 1 HTTP 404 (backend
# predates the drain feature), 2 anything else (unreachable, 5xx, 401...).
zm_probe() {
  zm_request GET ""
  case "$ZM_STATUS" in 200) return 0 ;; 404) return 1 ;; *) return 2 ;; esac
}

# Compact status table for ZM_BODY plus any plugin-runner pods ($1).
zm_table() {
  jq -r --arg pods "${1:-}" '
    def pad(w): tostring | . + ([range(0; w - length)] | map(" ") | join(""));
    def n(x): (x // []) | length;
    "draining=\(.draining) safeToRestart=\(.safeToRestart) active=\(n(.active)) paused=\(n(.paused)) blocking=\(n(.blocking)) worker-pods=\($pods | split("\n") | map(select(length > 0)) | length)",
    ((.active // [])[] | "  active    \((.kind // "?") | pad(14)) \(((.state // "?") + (if .pausable == false then ",no-pause" else "" end)) | pad(17)) \(.label // .runId) [\(.runId // "?")/\(.stepId // "?")]"),
    ((.blocking // [])[] | "  blocking  \((.kind // "?") | pad(14)) \("waiting" | pad(17)) \(.label // "?") - \(.reason // "")"),
    ($pods | split("\n")[] | select(length > 0) | "  pod       \("plugin-runner" | pad(14)) \("not finished" | pad(17)) \(sub("^pod/"; ""))")
  ' <<<"$ZM_BODY" 2>/dev/null || echo "  (unreadable status: ${ZM_BODY:0:200})"
}

# zm_drain REASON TTL_SECONDS -> 0 draining, 1 HTTP 404 (legacy backend), 2 error.
zm_drain() {
  local reason="$1" ttl="$2" body
  body="$(jq -cn --arg r "$reason" --argjson t "$ttl" '{reason: $r, ttlSeconds: $t}')"
  ZM_DRAINED=1   # from here on the EXIT trap resumes, even if the call half-failed
  zm_request POST /drain "$body"
  case "$ZM_STATUS" in
    200) ZM_DRAIN_ID="$(zm_json '.drainId // empty')"
         echo "    drain requested (drainId ${ZM_DRAIN_ID:-?}, expires $(zm_json '.expiresAt // "?"'))"
         return 0 ;;
    404) ZM_DRAINED=0; return 1 ;;
    *)   echo "!! drain request failed (HTTP $ZM_STATUS): ${ZM_BODY:0:300}" >&2; return 2 ;;
  esac
}

# Print the current status once (used by --force).
zm_show_status() {
  local pods=""
  zm_request GET ""
  [[ "$ZM_PLUGIN_POD_CHECK" == "1" ]] && pods="$(zm_plugin_pods)"
  if [[ "$ZM_STATUS" == "200" ]]; then zm_table "$pods"; else echo "    (status unavailable: HTTP $ZM_STATUS)"; fi
}

# zm_wait_safe TIMEOUT -> 0 once safeToRestart and no plugin-runner pods remain,
# 1 on timeout. Reprints the table whenever it changes, otherwise a heartbeat.
zm_wait_safe() {
  local timeout="$1" start=$SECONDS last="" last_print=$SECONDS table pods elapsed
  while :; do
    elapsed=$(( SECONDS - start ))
    pods=""
    zm_request GET ""
    if [[ "$ZM_STATUS" == "200" ]]; then
      [[ "$ZM_PLUGIN_POD_CHECK" == "1" ]] && pods="$(zm_plugin_pods)"
      table="$(zm_table "$pods")"
      if [[ "$(zm_json '.safeToRestart')" == "true" && -z "$pods" ]]; then
        printf '[%4ds] safe to restart\n%s\n' "$elapsed" "$table"
        return 0
      fi
    else
      table="status unavailable (HTTP $ZM_STATUS) - retrying"
    fi
    if [[ "$table" != "$last" ]]; then
      printf '[%4ds] %s\n' "$elapsed" "$table"; last="$table"; last_print=$SECONDS
    elif (( SECONDS - last_print >= ZM_HEARTBEAT_SECONDS )); then
      printf '[%4ds] still waiting: %s\n' "$elapsed" "${table%%$'\n'*}"; last_print=$SECONDS
    fi
    if (( elapsed >= timeout )); then return 1; fi
    sleep "$ZM_POLL_SECONDS"
  done
}

# POST resume against ZM_TARGET, then confirm draining:false. 0 on success.
zm_resume_target() {
  local body='{}'
  [[ -n "$ZM_DRAIN_ID" ]] && body="$(jq -cn --arg d "$ZM_DRAIN_ID" '{drainId: $d}')"
  zm_request POST /resume "$body"
  if [[ "$ZM_STATUS" != "200" ]]; then
    echo "!! resume on ${ZM_TARGET:-backend} failed (HTTP $ZM_STATUS): ${ZM_BODY:0:300}" >&2; return 1
  fi
  local resumed; resumed="$(zm_json '.resumed // 0')"
  zm_request GET ""
  if [[ "$ZM_STATUS" == "200" && "$(zm_json '.draining')" == "false" ]]; then
    echo "    resumed ${resumed} paused step(s) on ${ZM_TARGET:-backend}; draining=false"
    ZM_RESUMED=1; return 0
  fi
  echo "!! resume sent but ${ZM_TARGET:-backend} still reports draining=$(zm_json '.draining') (HTTP $ZM_STATUS)" >&2
  return 1
}

# zm_resume_new WAIT -> wait for the newest live backend pod to answer, resume
# there, verify. 0 on success (also when the new backend has no endpoint).
zm_resume_new() {
  local wait="$1" start=$SECONDS pod=""
  while :; do
    if [[ -z "${ZOER_MAINTENANCE_URL:-}" ]]; then pod="$(zm_pods live | head -1)"; ZM_TARGET="$pod"; fi
    if [[ -n "${ZOER_MAINTENANCE_URL:-}" || -n "$pod" ]]; then
      zm_request GET ""
      [[ "$ZM_STATUS" == "200" ]] && break
      if [[ "$ZM_STATUS" == "404" ]]; then
        echo "!! the new backend has no maintenance endpoint; it cannot resume work paused by the old one." >&2
        echo "   Paused steps stay parked; deploy a backend with the drain feature and run the resume command below." >&2
        return 1
      fi
    fi
    if (( SECONDS - start >= wait )); then
      echo "!! no new backend pod answered the maintenance API within ${wait}s" >&2; return 1
    fi
    sleep "$ZM_POLL_SECONDS"
  done
  zm_resume_target
}

# Try resume on whichever backend pod answers (live pods first, then
# terminating ones), retrying until WAIT seconds pass.
zm_resume_any() {
  local wait="$1" start=$SECONDS pod
  while :; do
    if [[ -n "${ZOER_MAINTENANCE_URL:-}" ]]; then
      ZM_TARGET=""; zm_resume_target && return 0
    else
      for pod in $(zm_pods live) $(zm_pods terminating); do
        ZM_TARGET="$pod"
        zm_request GET ""
        if [[ "$ZM_STATUS" == "200" ]]; then zm_resume_target && return 0; fi
      done
    fi
    if (( SECONDS - start >= wait )); then return 1; fi
    echo "    waiting for a backend pod to answer... ($(( SECONDS - start ))s/${wait}s, Ctrl-C to give up)"
    sleep "$ZM_POLL_SECONDS"
  done
}

zm_manual_hint() {
  cat >&2 <<EOF
   Resume by hand once a backend pod is Running:
     kubectl -n $ZM_NS exec deploy/$ZM_DEPLOY -c $ZM_CONTAINER -- bun -e \\
       'const r=await fetch("http://127.0.0.1:"+(process.env.PORT||4000)+"/api/internal/maintenance/resume",{method:"POST",headers:{"content-type":"application/json"},body:"{}"});console.log(r.status,await r.text())'
   If nobody resumes, the drain expires on its own (ttl) and the backend resumes paused work itself.
EOF
}

# EXIT trap: if we drained and did not resume, resume on whichever pod answers.
zm_on_exit() {
  local rc=$?
  [[ "$ZM_DRAINED" == "1" && "$ZM_RESUMED" != "1" ]] || return 0
  set +e
  trap 'echo; echo "!! gave up resuming." >&2; zm_manual_hint; exit 130' INT TERM
  echo >&2
  echo "==> deploy stopped (exit $rc) while Zoer was drained - resuming paused work" >&2
  if zm_resume_any "$ZM_TRAP_WAIT"; then
    echo "    work resumed; the deploy itself did not complete (exit $rc)." >&2
  else
    echo "!! could not resume automatically." >&2
    zm_manual_hint
  fi
  return 0
}
