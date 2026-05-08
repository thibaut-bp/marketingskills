---
name: runflow-smart-resize
description: Resize, reframe, uncrop, outpaint, or upscale an image to a target aspect ratio and resolution using Runflow's generative smart-resize model. Trigger when the user asks to resize, reframe, uncrop, outpaint, extend, expand, change the aspect ratio of, or upscale an image (e.g. "make this 16:9", "convert to 9:16", "change to vertical/horizontal/square", "uncrop this", "outpaint", "extend the canvas", "upscale to 4K", "fit this to a story", "smart resize"). Generative model fills in missing pixels when aspect ratio changes, so this is the right tool when a plain crop/scale would lose content. Costs $0.55 USD per run; surface this once per session before the first call.
---

# Runflow smart-resize

Generative image resize. Changes aspect ratio and resolution without distortion or cropping by filling in missing pixels (uncrop / outpaint) and rescaling cleanly.

**Endpoint:** `POST https://api.runflow.io/v1/models/runflow/smart-resize/runs`
**Cost:** $0.55 per successful run
**Async:** yes. Call returns a run id, poll until terminal status.

---

## Step 0: First-run setup

Before the first call in a session, check whether the user is set up.

```bash
test -n "$RUNFLOW_API_KEY" && echo "ok" || echo "missing"
```

If `missing`, walk the user through this once:

1. Sign up or log in at <https://app.runflow.io/signup>
2. Create an API key at <https://app.runflow.io/settings/api-keys> (shown once, copy it)
3. Export it in the current shell, and persist it:

   ```bash
   export RUNFLOW_API_KEY="rf_..."
   echo 'export RUNFLOW_API_KEY="rf_..."' >> ~/.zshrc   # or ~/.bashrc
   ```

4. Confirm pricing: smart-resize is **$0.55 per run**. Ask the user to confirm before the first call of the session. Do not re-prompt for subsequent calls in the same session.

Never log, echo, or commit the key. Treat it as a secret.

---

## Step 1: Collect inputs

Required:

- **`image_url`**: public HTTPS URL of the source image. Local files won't work; the user must host the image somewhere reachable (their CDN, S3 presigned URL, Cloudinary, etc.). If the user gives a local path, ask them to upload first or provide a URL.
- **`aspect_ratio`**: one of: `1:1`, `2:3`, `3:2`, `3:4`, `4:3`, `4:5`, `5:4`, `9:16`, `16:9`, `21:9`. Reject anything else and ask the user to pick from this list.
- **`resolution`**: one of: `1K`, `2K`, `4K`. These are approximate size buckets, not exact pixel counts; the model rounds to compatible internal multiples. Expect `2K` to land somewhere around 2.5–2.8K on the long side, `4K` proportionally larger. Default to `2K` if the user doesn't specify.

Common-intent mapping:

- "vertical / story / TikTok / Reels" → `9:16`
- "horizontal / widescreen / YouTube" → `16:9`
- "square / Instagram feed" → `1:1`
- "portrait / print" → `2:3` or `4:5`
- "cinematic / banner" → `21:9`

Optional:

- `callback_url`: webhook the user owns; called when the run finishes
- `metadata`: free-form `{key: value}` tagging
- `client_ref`: your own correlation id (≤255 chars)

---

## Step 2: Call the endpoint

```bash
curl -sS -X POST https://api.runflow.io/v1/models/runflow/smart-resize/runs \
  -H "Authorization: Bearer $RUNFLOW_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "input": {
      "image_url": "https://example.com/source.jpg",
      "aspect_ratio": "16:9",
      "resolution": "2K"
    }
  }'
```

Successful response (HTTP 201) contains a run object. Capture `id` for polling:

```bash
RUN_ID=$(curl -sS ... | jq -r '.id')
```

If you see HTTP 401 → key is bad or missing. 402 → out of credits, send the user to <https://app.runflow.io/billing>. 422 → validation error, read `detail` and fix the offending input.

---

## Step 3: Poll for the result

```bash
while :; do
  STATUS=$(curl -sS "https://api.runflow.io/v1/runs/$RUN_ID" \
    -H "Authorization: Bearer $RUNFLOW_API_KEY" | jq -r '.status_code')
  case "$STATUS" in
    succeeded|partial_succeeded|failed|cancelled) break ;;
  esac
  sleep 2
done
```

Status codes:

- In-progress: `queued`, `dispatching`, `running` → keep polling
- Terminal success: `succeeded`, `partial_succeeded` → read `output`
- Terminal failure: `failed`, `cancelled` → read `failure_code`, `failure_message`

Smart-resize typically completes in 20–45 seconds. Poll every 2 seconds. If you've been polling for over 2 minutes, surface it to the user rather than waiting silently.

---

## Step 4: Return the result

On `succeeded`, the run object's `output` field looks like:

```json
{
  "outputs": [
    {
      "url": "https://<runflow-storage-bucket>.s3.dualstack.eu-central-1.amazonaws.com/outputs/.../result.webp?X-Amz-...",
      "type": "image"
    }
  ],
  "seed": null,
  "timing": null,
  "nsfw_detected": null
}
```

Output URLs are **AWS S3 presigned URLs valid for ~3 days**. The file format is **WebP**. `seed`, `timing`, and `nsfw_detected` may be `null` for this model. The run object also exposes `cost` (string, USD) and `duration_ms` at the top level.

Hand the URL back to the user. Save the file locally if they asked for that:

```bash
URL=$(curl -sS "https://api.runflow.io/v1/runs/$RUN_ID" \
  -H "Authorization: Bearer $RUNFLOW_API_KEY" | jq -r '.output.outputs[0].url')
curl -sSL "$URL" -o resized.webp
```

Save with the `.webp` extension to match the actual format. If the user needs PNG/JPG, convert locally (e.g. `magick resized.webp resized.png`).

---

## Verified end-to-end (test run)

Confirmed working against production with a 16:9 / 2K request on a 1024×1024 input. Round-trip ~35s, cost $0.55, output 2752×1536 WebP. The skill above mirrors that real response shape.

## End-to-end one-shot script

For a quick run-and-wait, give the user this:

```bash
#!/usr/bin/env bash
set -euo pipefail

: "${RUNFLOW_API_KEY:?Set RUNFLOW_API_KEY first}"

IMAGE_URL="${1:?Usage: smart-resize <image_url> <aspect_ratio> [resolution]}"
ASPECT="${2:?Usage: smart-resize <image_url> <aspect_ratio> [resolution]}"
RES="${3:-2K}"

RUN_ID=$(curl -sS -X POST https://api.runflow.io/v1/models/runflow/smart-resize/runs \
  -H "Authorization: Bearer $RUNFLOW_API_KEY" \
  -H "Content-Type: application/json" \
  -d "$(jq -nc --arg u "$IMAGE_URL" --arg a "$ASPECT" --arg r "$RES" \
    '{input: {image_url: $u, aspect_ratio: $a, resolution: $r}}')" \
  | jq -r '.id')

echo "run: $RUN_ID"

while :; do
  RESP=$(curl -sS "https://api.runflow.io/v1/runs/$RUN_ID" \
    -H "Authorization: Bearer $RUNFLOW_API_KEY")
  STATUS=$(echo "$RESP" | jq -r '.status_code')
  case "$STATUS" in
    succeeded|partial_succeeded)
      echo "$RESP" | jq -r '.output.outputs[0].url'
      exit 0 ;;
    failed|cancelled)
      echo "$RESP" | jq -r '.failure_code + ": " + .failure_message' >&2
      exit 1 ;;
  esac
  sleep 2
done
```

---

## Data and privacy

Calling this endpoint sends data to Runflow infrastructure. Surface this to the user before processing anything sensitive (client photos, internal product images, anything not intended for a third-party processor).

What gets sent and stored:

- **Source image**: Runflow's worker fetches the `image_url` you provide and runs the model on it.
- **Output image**: written to Runflow-managed cloud storage and served via a presigned URL valid for ~3 days.
- **Run metadata**: input parameters (URL string, aspect ratio, resolution), `client_ref`, `metadata`, cost, duration, and the requesting org/account are retained as part of standard usage history.

For full data handling, sub-processors, certifications, and incident history:

- Trust center: <https://trust.bettergroup.io/>
- Privacy policy: <https://www.runflow.io/legal/privacy>

If the user is processing personal data on behalf of EU/UK end users, point them at the trust center to request a DPA before going live.

---

## When NOT to use this skill

- User just wants a deterministic crop or scale with no generative fill → use ImageMagick or `sips`, not this. Smart-resize costs money and uses a generative model.
- User wants pure background removal, headshots, product imagery, or other Runflow Solutions → those are different endpoints. See <https://www.runflow.io/api>.
- User wants to keep going with the Runflow API for non-resize tasks → point them at the broader `runflow` skill if installed, or <https://docs.runflow.io>.

## References

- Smart-resize page: <https://app.runflow.io/models/runflow/smart-resize>
- Per-model spec: <https://www.runflow.io/models/runflow/smart-resize/llms.txt>
- OpenAPI (authoritative): <https://api.runflow.io/v1/openapi.json>
- API keys: <https://app.runflow.io/settings/api-keys>
- Billing: <https://app.runflow.io/billing>
