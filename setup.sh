#!/usr/bin/env bash
# setup.sh — Install the kocreator-kokoro TTS plugin (official Kokoro TTS, hexgrad) on Ubuntu.
#
# Installs espeak-ng, builds this folder's own per-machine venv from uv.lock,
# and downloads the Kokoro model and voice (~327 MB, needs internet once) via
# a smoke test. After this, kocreator can use the plugin fully offline.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"
# Per-machine venv (.venv-<hostname>) — see uv-env.sh. A caller's uv
# environment (kocreator's, for instance) must not be reused here.
unset UV_PROJECT_ENVIRONMENT VIRTUAL_ENV
source "$HERE/uv-env.sh"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ── Step 1: System dependencies ────────────────────────────────────
info "Installing system dependencies (espeak-ng)..."
sudo apt-get update -qq
sudo apt-get install -y espeak-ng

# ── Step 2: uv ─────────────────────────────────────────────────────
# uv manages the Python interpreter and the virtualenv. It reads
# .python-version (3.12 — kokoro requires Python <3.13) and downloads that
# interpreter into its shared store if the machine doesn't already have one.
if ! command -v uv >/dev/null 2>&1; then
    error "uv is required but was not found in PATH."
    error "Install it from https://docs.astral.sh/uv/ or via: curl -LsSf https://astral.sh/uv/install.sh | sh"
    exit 1
fi

# ── Step 3: Install Python dependencies ────────────────────────────
# --locked installs exactly what uv.lock records (and fails if pyproject.toml
# has drifted from it), so re-running setup.sh converges the venv back onto the
# known-good set.
info "Installing Python dependencies from uv.lock..."
uv sync --locked
info "Venv:   $UV_PROJECT_ENVIRONMENT"
info "Python: $(uv run python --version)"

# ── Step 4: Smoke test (also downloads the model) ──────────────────
# Run online, unlike tts.sh (which forces HF_HUB_OFFLINE), so the first run
# fetches the model and voice into ~/.cache/huggingface/.
info "Running smoke test with am_liam voice (downloads the model on first run)..."
rm -f test_output.wav
uv run python -c "
from kokoro import KPipeline
import soundfile as sf

pipeline = KPipeline(lang_code='a')
generator = pipeline('[Kokoro](/kˈOkəɹO/) setup is complete.', voice='am_liam')
for i, (gs, ps, audio) in enumerate(generator):
    sf.write('test_output.wav', audio, 24000)
    break
"

if [ -s test_output.wav ]; then
    info "Smoke test passed! test_output.wav created successfully."
else
    warn "Smoke test did not produce output. Try running manually."
fi

echo ""
echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN} kocreator-kokoro setup complete!${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
echo ""
echo "  Source: https://github.com/hexgrad/kokoro (Apache 2.0)"
echo "  G2P: misaki — supports [word](/phonemes/) pronunciation overrides"
echo ""
echo "  Point kocreator at this plugin, in kocreator.toml:"
echo '    tts_plugin = "../kocreator-kokoro"'
echo "  Or speak files directly (one input<TAB>output<TAB>seed line per job):"
echo "    ./tts.sh speak jobs.tsv"
echo ""
