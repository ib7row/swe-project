"""
Ingestion Service (Publisher / Factor 9-compliant)
- Accepts PNG file uploads via HTTP POST
- Stores raw file in GCS raw-files bucket
- GCS event → Eventarc → Worker Service (Subscriber)
- Reads ALL config from environment variables (Factor 3)
- Handles SIGTERM gracefully (Factor 9)
"""

import logging
import os
import signal
import sys
import uuid

from flask import Flask, jsonify, render_template, request
from google.cloud import storage

# ── Factor 11: Logs ──────────────────────────────────────────────────────────
# Log to stdout/stderr as plain event streams; never manage log files.
logging.basicConfig(
    stream=sys.stdout,
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
logger = logging.getLogger(__name__)

# ── Factor 3: Config from environment ────────────────────────────────────────
PROJECT_ID   = os.environ["GCP_PROJECT_ID"]          # required — crash fast if missing
RAW_BUCKET   = os.environ["GCS_RAW_BUCKET"]          # e.g. "my-project-raw-uploads"
ALLOWED_MIME = {"image/png"}

app = Flask(__name__)

storage_client = storage.Client()


# ── Factor 9: Graceful shutdown ───────────────────────────────────────────────
_shutdown = False

def _handle_sigterm(signum, frame):
    """
    Cloud Run sends SIGTERM before killing a container.
    We set a flag so in-flight requests can complete, then exit cleanly.
    Gunicorn's --timeout ensures we don't hang forever.
    """
    global _shutdown
    logger.info("SIGTERM received — draining in-flight requests before shutdown")
    _shutdown = True

signal.signal(signal.SIGTERM, _handle_sigterm)


# ── Routes ───────────────────────────────────────────────────────────────────

@app.route("/healthz")
def healthz():
    """Liveness probe endpoint for Cloud Run / load balancers."""
    if _shutdown:
        return jsonify({"status": "shutting_down"}), 503
    return jsonify({"status": "ok"}), 200


@app.route("/", methods=["GET", "POST"])
def home():
    if _shutdown:
        return jsonify({"error": "service is shutting down"}), 503

    status = ""
    error  = ""

    if request.method == "POST":
        file = request.files.get("file")

        if not file or file.filename == "":
            error = "No file selected."
        elif file.mimetype not in ALLOWED_MIME:
            error = f"Only PNG files are accepted. Got: {file.mimetype}"
        else:
            try:
                # Generate a unique object name to avoid collisions (Factor 6: Stateless)
                object_name = f"uploads/{uuid.uuid4().hex}_{file.filename}"
                bucket = storage_client.bucket(RAW_BUCKET)
                blob   = bucket.blob(object_name)
                blob.upload_from_file(file, content_type=file.mimetype)

                logger.info("Uploaded %s to gs://%s/%s", file.filename, RAW_BUCKET, object_name)
                status = f"✅ Uploaded '{file.filename}' — conversion queued automatically."
            except Exception as exc:
                logger.exception("Upload failed: %s", exc)
                error = "Upload failed. Please try again."

    return render_template("index.html", status=status, error=error)


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080, debug=False)
