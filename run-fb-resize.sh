#!/usr/bin/env bash
# Run smart-resize for the 4 Facebook ad ratios in parallel.
# Reads RUNFLOW_API_KEY from the local .env (or env).
set -euo pipefail

[ -f .env ] && set -a && . ./.env && set +a
: "${RUNFLOW_API_KEY:?RUNFLOW_API_KEY not set}"

IMAGE_URL="https://i.imgur.com/JEuHFk5.png"
RES="2K"

submit() {
  local ratio="$1" tag="$2"
  curl -sS -X POST https://api.runflow.io/v1/models/runflow/smart-resize/runs \
    -H "Authorization: Bearer $RUNFLOW_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$(jq -nc --arg u "$IMAGE_URL" --arg a "$ratio" --arg r "$RES" --arg c "$tag" \
      '{input:{image_url:$u, aspect_ratio:$a, resolution:$r}, client_ref:$c}')" \
    | jq -r '.id'
}

poll() {
  local run_id="$1" label="$2"
  while :; do
    local resp
    resp=$(curl -sS "https://api.runflow.io/v1/runs/$run_id" \
      -H "Authorization: Bearer $RUNFLOW_API_KEY")
    local status
    status=$(echo "$resp" | jq -r '.status_code')
    case "$status" in
      succeeded|partial_succeeded)
        printf '%-18s %s\n' "$label" "$(echo "$resp" | jq -r '.output.outputs[0].url')"
        return 0 ;;
      failed|cancelled)
        printf '%-18s FAILED: %s\n' "$label" \
          "$(echo "$resp" | jq -r '.failure_code + ": " + .failure_message')" >&2
        return 1 ;;
    esac
    sleep 2
  done
}

echo "Submitting 4 runs..."
ID_45=$(submit  "4:5" fb-feed-portrait)
ID_11=$(submit  "1:1" fb-feed-square)
ID_916=$(submit "9:16" fb-stories)
ID_169=$(submit "16:9" fb-landscape)
echo "  4:5 portrait  -> $ID_45"
echo "  1:1 square    -> $ID_11"
echo "  9:16 vertical -> $ID_916"
echo "  16:9 landscape-> $ID_169"
echo
echo "Polling..."
poll "$ID_45"  "4:5 portrait"  &
poll "$ID_11"  "1:1 square"    &
poll "$ID_916" "9:16 vertical" &
poll "$ID_169" "16:9 landscape" &
wait
