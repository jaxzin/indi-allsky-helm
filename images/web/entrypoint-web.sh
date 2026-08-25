#!/bin/bash
# Web image entrypoint: render the flask config, then hand the process over to
# gunicorn. Schema work is NOT done here — it belongs to migrate.sh, which the
# chart runs as an initContainer, so that N replicas of this container never
# race each other over the same Alembic history.

set -o errexit
set -o nounset
set -o pipefail

ALLSKY_DIRECTORY="/home/allsky/indi-allsky"

# gunicorn settings. Values are upstream parity with
# docker/start_gunicorn.sh:159-166 — named here so the invocation carries no
# bare numbers.
GUNICORN_BIND="0.0.0.0:8000"
GUNICORN_WORKER_CLASS="gthread"
GUNICORN_THREADS="8"
GUNICORN_TIMEOUT="180"
GUNICORN_UMASK="0022"
GUNICORN_LOG_LEVEL="info"
GUNICORN_APP="indi_allsky.wsgi"

# Fails fast (non-zero, before gunicorn starts) on a missing or malformed
# setting, naming the offending variable.
/home/allsky/render-flask-config.sh

# flask/gunicorn resolve the application from ./app.py in the checkout —
# upstream ships no FLASK_APP — so the working directory is part of the
# contract, not a convenience.
cd "$ALLSKY_DIRECTORY"

# shellcheck disable=SC1091  # created by upstream's Dockerfile at image build time; not in this repo
source /home/allsky/venv/bin/activate

# Send gunicorn's error log to stderr so it lands in `kubectl logs`.
export GUNICORN_ERROR_LOG_HANDLER=wsgi

# Consumed by upstream code to detect a containerised deployment.
export INDIALLSKY_DOCKER=1

# FORWARDED_ALLOW_IPS is deliberately NOT exported here. Upstream's compose
# stack sets it to "*", which trusts X-Forwarded-* from any peer; gunicorn's
# own default (127.0.0.1,::1) is exactly right for this chart, where the only
# thing in front of gunicorn is the nginx sidecar in the same pod — i.e. the
# same loopback. gunicorn reads FORWARDED_ALLOW_IPS from the environment
# natively, so a deployment with a different topology can still set it from
# the chart without this image taking a position.

exec gunicorn \
    --bind "$GUNICORN_BIND" \
    --worker-class "$GUNICORN_WORKER_CLASS" \
    --threads "$GUNICORN_THREADS" \
    --timeout "$GUNICORN_TIMEOUT" \
    --umask "$GUNICORN_UMASK" \
    --log-level "$GUNICORN_LOG_LEVEL" \
    "$GUNICORN_APP"
