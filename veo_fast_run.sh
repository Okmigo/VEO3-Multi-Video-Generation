#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID="kavodaiservices-468008"
LOCATION="us-central1"
BUCKET="valleymystvids"

MODEL_ID="veo-3.0-fast-generate-001"   # Veo 3 Fast
RESOLUTION="1080p"
ASPECT="16:9"
BIN=8
SAMPLE_COUNT=1
CONCURRENCY=4

SCENES_FILE="${1:-scenes.csv}"

gcloud config set project "$PROJECT_ID" >/dev/null
ACCESS_TOKEN=$(gcloud auth application-default print-access-token)

TS=$(date +%Y%m%d-%H%M%S)
WORK="ops/veo_fast_prebaked_${TS}"
mkdir -p "$WORK/submit"

# copy scenes file into work
cp "$SCENES_FILE" "$WORK/scenes.csv"

# Show plan
python3 - <<'PY' "$WORK/scenes.csv"
import sys,csv,math
csvp=sys.argv[1]
with open(csvp,encoding='utf-8') as f:
    r=list(csv.DictReader(f))
clips=len(r); dur=float(r[-1]['end'])
print(f"Plan: {clips} clips × 8s = ~{clips*8/60:.2f} min covering {dur:.2f}s.")
PY

OUT_PREFIX="gs://$BUCKET/veo/$TS"
tail -n +2 "$WORK/scenes.csv" | while IFS=, read -r SCENE_ID START END CAPTION PROMPT; do
  REQ="$WORK/submit/${SCENE_ID}.json"
  jq -n     --arg prompt "$PROMPT"     --arg storage "${OUT_PREFIX}/${SCENE_ID}/"     --arg aspect "$ASPECT"     --arg res "$RESOLUTION"     --argjson dur $BIN     --argjson cnt $SAMPLE_COUNT     '{
      instances: [{ prompt: $prompt }],
      parameters: {
        storageUri: $storage,
        aspectRatio: $aspect,
        durationSeconds: $dur,
        sampleCount: $cnt,
        resolution: $res
      }
    }' > "$REQ"

  (
    RESP=$(curl -sS -X POST       -H "Authorization: Bearer $ACCESS_TOKEN"       -H "x-goog-user-project: $PROJECT_ID"       -H "Content-Type: application/json; charset=utf-8"       -d @"$REQ"       "https://$LOCATION-aiplatform.googleapis.com/v1/projects/$PROJECT_ID/locations/$LOCATION/publishers/google/models/$MODEL_ID:predictLongRunning")

    OP=$(echo "$RESP" | jq -r '.name // empty')
    if [[ -z "$OP" ]]; then echo "!! Submit failed for $SCENE_ID"; echo "$RESP"; exit 1; fi

    while true; do
      HTTP=$(curl -sS -o "$WORK/${SCENE_ID}.status.json" -w "%{http_code}"         -H "Authorization: Bearer $ACCESS_TOKEN"         -H "x-goog-user-project: $PROJECT_ID"         "https://$LOCATION-aiplatform.googleapis.com/v1/$OP")
      [[ "$HTTP" != "200" ]] && echo "HTTP $HTTP for $SCENE_ID" && head -c 300 "$WORK/${SCENE_ID}.status.json" && exit 1
      DONE=$(jq -r '.done // false' "$WORK/${SCENE_ID}.status.json")
      PCT=$(jq -r '.metadata.progressPercentage // 0' "$WORK/${SCENE_ID}.status.json")
      printf "%s: %s%%\r" "$SCENE_ID" "$PCT"
      [[ "$DONE" == "true" ]] && break
      sleep 5
    done
    echo; echo "$SCENE_ID done"
  ) &
  while (( $(jobs -r | wc -l) >= CONCURRENCY )); do sleep 1; done
done
wait

echo "Downloading all clips locally…"
gcloud storage cp "${OUT_PREFIX}/**/*.mp4" . >/dev/null || true
echo "Done. Outputs under $OUT_PREFIX and current folder."
