#!/usr/bin/env bash
# tts.sh — kocreator TTS plugin for Kokoro TTS (hexgrad, Apache 2.0).
#
# Self-contained: Kokoro runs in this folder's own uv virtualenv, set up once
# with ./setup.sh. This script implements the kocreator plugin contract (see
# "Writing a TTS plugin" in kocreator's README.md):
#
#   tts.sh check              exit 0 when Kokoro is installed
#   tts.sh settings           print the audio settings as JSON
#   tts.sh speak <jobs.tsv>   speak every job (input<TAB>output<TAB>seed per line),
#                             loading the model once; seeds are ignored (Kokoro is
#                             deterministic)
set -euo pipefail

# ── Voice settings ─────────────────────────────────────────────────
# kocreator caches each clip against the `settings` output: change one here
# and every narration is regenerated on the next run.
VOICE="am_liam"   # NOTE: originally 'bm_daniel'. The first letter picks the language (a = American English)
SPEED="1.0"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    echo "Usage: $0 check | settings | speak <jobs.tsv>" >&2
    exit 2
}

# Kokoro runs in this plugin's own per-machine venv (.venv-<hostname>), never
# in a caller's: drop whatever uv environment the caller had, then pick ours.
use_own_venv() {
    unset UV_PROJECT_ENVIRONMENT VIRTUAL_ENV
    # shellcheck source=uv-env.sh
    source "$HERE/uv-env.sh"
}

cmd_check() {
    if ! command -v uv >/dev/null 2>&1; then
        echo "uv is required but was not found in PATH." >&2
        exit 1
    fi
    use_own_venv
    if [ ! -x "$UV_PROJECT_ENVIRONMENT/bin/python" ] ||
        ! "$UV_PROJECT_ENVIRONMENT/bin/python" -c \
            'import importlib.util, sys; sys.exit(importlib.util.find_spec("kokoro") is None)' 2>/dev/null; then
        echo "Kokoro is not installed for this machine ($UV_PROJECT_ENVIRONMENT)." >&2
        echo "Run it once with:  cd $HERE && ./setup.sh" >&2
        exit 1
    fi
}

cmd_settings() {
    printf '{"engine": "kokoro", "voice": "%s", "speed": %s}\n' "$VOICE" "$SPEED"
}

cmd_speak() {
    [ $# -eq 1 ] || usage
    local jobs="$1"
    use_own_venv
    # The jobs file holds absolute paths; its own path is made absolute too
    # because --directory runs from this folder.
    exec uv run --locked --directory "$HERE" python "$HERE/kokoro-batch.py" \
        "$(realpath -m "$jobs")" --voice "$VOICE" --speed "$SPEED"
}

[ $# -ge 1 ] || usage
command="$1"
shift
case "$command" in
    check)    cmd_check ;;
    settings) cmd_settings ;;
    speak)    cmd_speak "$@" ;;
    *)        usage ;;
esac
