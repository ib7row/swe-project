"""
Worker Service (Subscriber / Factor 9-compliant)
- Receives Eventarc CloudEvent HTTP push notifications from GCS
- Downloads the raw PNG from GCS
- Converts to JPG and PDF
- Uploads converted files to the output GCS bucket
- Reads ALL config from environment variables (Factor 3)
- Handles SIGTERM gracefully (Factor 9)
"""

import base64
import json
import logging
import os
import signal
import sys
import tempfile

from flask import Flask, jsonify, request
from google.cloud import storage
from PIL import Image

# ── Factor 11: Logs ──────────────────────────────────────────────────────────
logging.basicConfig(
    stream=sys.stdout,
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
logger = logging.getLogger(__name__)

# ── Factor 3: Config ─────────────────────────────────────────────────────────
PROJECT_ID    = os.environ["GCP_PROJECT_ID"]
RAW_BUCKET    = os.environ["GCS_RAW_BUCKET"]
OUTPUT_BUCKET = os.environ["GCS_OUTPUT_BUCKET"]

app = Flask(__name__)
storage_client = storage.Client()


# ── Factor 9: Graceful shutdown ───────────────────────────────────────────────
_shutdown = False

def _handle_sigterm(signum, frame):
    """
    Cloud Run sends SIGTERM 10 seconds before forceful SIGKILL.
    We mark the service as draining so healthz returns 503 (removes from LB),
    while gunicorn's --graceful-timeout lets in-flight conversions complete.
    """
    global _shutdown
    logger.info("SIGTERM received — draining worker, no new jobs accepted")
    _shutdown = True

signal.signal(signal.SIGTERM, _handle_sigterm)


def _convert_png(raw_bucket_name: str, object_name: str) -> dict:
    """Download PNG from GCS, convert to JPG + PDF, upload outputs."""
    bucket     = storage_client.bucket(raw_bucket_name)
    out_bucket = storage_client.bucket(OUTPUT_BUCKET)

    with tempfile.TemporaryDirectory() as tmpdir:
        png_path = os.path.join(tmpdir, "input.png")

        # Download
        bucket.blob(object_name).download_to_filename(png_path)
        logger.info("Downloaded gs://%s/%s", raw_bucket_name, object_name)

        base_name = os.path.splitext(os.path.basename(object_name))[0]
        img = Image.open(png_path).convert("RGB")

        results = {}

        # ── Convert to JPG ────────────────────────────────────────────────
        jpg_path        = os.path.join(tmpdir, f"{base_name}.jpg")
        jpg_object_name = f"converted/{base_name}.jpg"
        img.save(jpg_path, "JPEG", quality=90)
        out_bucket.blob(jpg_object_name).upload_from_filename(jpg_path, content_type="image/jpeg")
        logger.info("Uploaded JPG → gs://%s/%s", OUTPUT_BUCKET, jpg_object_name)
        results["jpg"] = jpg_object_name

        # ── Convert to PDF ────────────────────────────────────────────────
        pdf_path        = os.path.join(tmpdir, f"{base_name}.pdf")
        pdf_object_name = f"converted/{base_name}.pdf"
        img.save(pdf_path, "PDF", resolution=100)
        out_bucket.blob(pdf_object_name).upload_from_filename(pdf_path, content_type="application/pdf")
        logger.info("Uploaded PDF → gs://%s/%s", OUTPUT_BUCKET, pdf_object_name)
        results["pdf"] = pdf_object_name

    return results


# ── Routes ───────────────────────────────────────────────────────────────────

@app.route("/healthz")
def healthz():
    """Liveness/readiness probe. Returns 503 during graceful drain."""
    if _shutdown:
        return jsonify({"status": "shutting_down"}), 503
    return jsonify({"status": "ok"}), 200


@app.route("/", methods=["POST"])
def handle_event():
    """
    Eventarc delivers a CloudEvent as an HTTP POST.
    The GCS notification payload is in the request body (JSON).
    """
    if _shutdown:
        # Return 429 so Eventarc will retry after we restart
        return jsonify({"error": "service is draining, please retry"}), 429

    try:
        envelope = request.get_json(force=True, silent=True) or {}

        # Eventarc wraps the GCS notification inside CloudEvents attributes.
        # The bucket and object are in the data payload.
        data = envelope.get("data", {})

        # Support both direct GCS event format and base64-encoded Pub/Sub wrapper
        if isinstance(data, str):
            data = json.loads(base64.b64decode(data).decode("utf-8"))

        bucket_name = data.get("bucket") or envelope.get("bucket", RAW_BUCKET)
        object_name = data.get("name")   or envelope.get("name")

        if not object_name:
            logger.warning("Received event with no object name: %s", envelope)
            return jsonify({"error": "missing object name"}), 400

        # Only process PNG uploads
        if not object_name.lower().endswith(".png"):
            logger.info("Skipping non-PNG object: %s", object_name)
            return jsonify({"status": "skipped", "reason": "not a PNG"}), 200

        logger.info("Processing conversion for gs://%s/%s", bucket_name, object_name)
        results = _convert_png(bucket_name, object_name)

        return jsonify({"status": "converted", "outputs": results}), 200

    except Exception as exc:
        logger.exception("Conversion failed: %s", exc)
        # Return 500 so Eventarc retries the event
        return jsonify({"error": str(exc)}), 500


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080, debug=False)
