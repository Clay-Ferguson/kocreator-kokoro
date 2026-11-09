# kocreator-kokoro

A **TTS plugin for [KoCreator](https://github.com/Clay-Ferguson/kocreator)**, built on [Kokoro TTS](https://github.com/hexgrad/kokoro) (hexgrad, Apache 2.0). It is self-contained: Kokoro runs in this folder's own uv virtualenv, entirely offline on your local CPU after the one-time setup. This was the engine of the original KoCreator, and it is KoCreator's default plugin.

It implements KoCreator's batch-only plugin contract (see "Writing a TTS Plugin" in KoCreator's README): `tts.sh speak <jobs.tsv>` loads Kokoro **once** and then speaks every narration in the batch, printing `KOCREATOR_DONE <n>` after each one. There is no single-file mode; one clip is a batch of one.

## Setup

Install [uv](https://docs.astral.sh/uv/) first, then run the one-time setup script. It installs `espeak-ng` via apt, builds the Python environment from `uv.lock`, and downloads the Kokoro model (~327 MB) and voice from HuggingFace by speaking one sentence into `test_output.wav`:

```bash
curl -LsSf https://astral.sh/uv/install.sh | sh   # if you don't already have uv
./setup.sh
```

The model is cached in `~/.cache/huggingface/` and only downloaded once. Then make sure `../kocreator/kocreator.toml` says `tts_plugin = "../kocreator-kokoro"` (the default).

**System requirements:** Ubuntu Linux and uv. You don't need a particular Python installed: `.python-version` pins 3.12, and uv downloads that interpreter into its shared store if your machine lacks it.

The virtualenv is **per machine**: `.venv-<hostname>/` (gitignored). A uv venv only works on the machine that built it, because `bin/python` is a symlink into that machine's uv interpreter store. So if this folder is shared between machines (for example a host and a VM mounting the same disk), one shared `.venv/` would break for whichever machine didn't build it last. `uv-env.sh` sets `UV_PROJECT_ENVIRONMENT` to `.venv-<hostname>`, and `setup.sh` and `tts.sh` source it (after dropping any caller's `UV_PROJECT_ENVIRONMENT`). Before running `uv` by hand, source the helper so `uv` uses this machine's venv rather than creating a plain `.venv/`:

```bash
source uv-env.sh
```

## Voice Settings

Set by variables at the top of `tts.sh`:

| Variable | Default | Notes |
|---|---|---|
| `VOICE` | `am_liam` | The first letter picks the language (`a` American English, `b` British, …). Originally `bm_daniel` |
| `SPEED` | `1.0` | Speech speed |

They are reported by `tts.sh settings` because they are part of KoCreator's cache key: change one and every narration is regenerated on the next run. Kokoro is deterministic, so a seed in the jobs file is noted in the log and ignored.

## Speaking Files Directly

`tts.sh speak` runs `kokoro-batch.py` on a jobs file: one line per narration, three tab-separated fields (`input.txt`, `output.wav`, seed or empty):

```bash
printf '%s\t%s\t\n' "$PWD/a.txt" "$PWD/a.wav" "$PWD/b.txt" "$PWD/b.wav" > jobs.tsv
./tts.sh speak jobs.tsv
uv run kokoro-batch.py jobs.tsv --voice af_heart --speed 1.2   # other voices, after `source uv-env.sh`
```

Loading Kokoro (importing torch and spaCy, then the weights) takes a few seconds, and in batch mode that happens once per run instead of once per clip. On the KoCreator test demo, all 10 clips were spoken in about 35 s, against about 107 s when each clip loaded the model on its own.

## Phonetic Overrides

Kokoro uses [misaki](https://github.com/hexgrad/misaki) for grapheme-to-phoneme conversion, which supports inline pronunciation overrides in your narration text:

```
[LaTeX](/lˈeɪtɛk/) renders mathematical formulas.
[Kokoro](/kˈOkəɹO/) is an open-weight TTS model.
```

Phoneme reference: https://github.com/hexgrad/misaki/blob/main/EN_PHONES.md

## Offline Mode

`kokoro-batch.py` sets `HF_HUB_OFFLINE=1` so it **never contacts the internet** during normal use. Only `setup.sh` needs internet access (on first run) to download the model weights.

## Threads

KoCreator caps `OMP_NUM_THREADS`, `MKL_NUM_THREADS` and `OPENBLAS_NUM_THREADS` and passes its thread budget in `KOCREATOR_THREADS`, which `kokoro-batch.py` hands to `torch.set_num_threads()` before the model loads.

## Dependencies

Python dependencies are declared in `pyproject.toml`, which pins the project's **direct**
dependencies to the versions it has been verified against. `uv.lock` records the exact
version of every package, transitive ones included (`transformers`, `spacy`,
`tokenizers`, ...), so a fresh `./setup.sh` (`uv sync --locked`) reproduces a known-good
environment.

`torch` is installed from PyTorch's **CPU-only** index rather than PyPI. The default PyPI
build for Linux bundles ~3.4 GB of NVIDIA CUDA runtime wheels (`nvidia-*`, `cuda-*`,
`triton`) whether or not the machine has an NVIDIA GPU, and Kokoro only ever chooses
between CUDA and CPU; its 82M-parameter model runs comfortably on CPU. If you have an
NVIDIA GPU and want to use it, delete the `torch` entry under `[tool.uv.sources]` in
`pyproject.toml`, then run `uv lock && uv sync`.

One entry is worth calling out: `en_core_web_sm`, the spaCy English pipeline that
misaki's grapheme-to-phoneme stage needs. It is not published to PyPI, so it is
referenced by its official release URL. Without that line, misaki calls
`spacy.cli.download()` the first time it runs, which quietly breaks the "no internet
after setup" guarantee on a fresh machine.

### Upgrading Dependencies

To move to newer releases:

1. Raise the pins in `pyproject.toml` (for example `torch==2.14.0`).
2. Re-resolve, install, and test:

```bash
uv lock                # re-resolve against the new pins; other locked versions are kept where possible
uv sync                # bring this machine's venv in line with the new lock (after `source uv-env.sh`)
../kocreator/test-generate.sh --plugin ../kocreator-kokoro   # confirm TTS and video output still work
```

3. Commit `pyproject.toml` and `uv.lock` together. After an upgrade that changes how speech sounds, delete KoCreator's `generated-wav/` folders, since the cache key doesn't include the engine's version.

To refresh only the transitive packages without touching the pins, run `uv lock --upgrade`.

**Python is pinned to 3.12.** Both `kokoro` and `misaki` declare
`requires-python = ">=3.10,<3.13"`, and `numpy` 2.5 requires 3.12 or newer, so
`pyproject.toml` declares `requires-python = ">=3.12,<3.13"` and `.python-version` pins
3.12. Moving to 3.13+ has to wait for new kokoro/misaki releases.

A few transitive packages are also held back by upper bounds and cannot go to their
newest releases: `thinc` (spaCy 3.8 requires `<8.4.0`), `tokenizers` (transformers
requires `<=0.23.0`), and `mpmath` (sympy requires `<1.4`).

Last verified (2026-08-18) on Python 3.12 with kokoro 0.9.4, misaki 0.9.4,
soundfile 0.14.0, torch 2.13.0, transformers 5.15.0, spacy 3.8.15, and numpy 2.5.2.

## Files

| File | Purpose |
|------|---------|
| `tts.sh` | The plugin: `check`, `settings`, `speak` |
| `kokoro-batch.py` | Loads Kokoro once and speaks every job in a jobs file |
| `setup.sh` | One-time setup: espeak-ng, the venv from `uv.lock`, model download and smoke test |
| `pyproject.toml` / `uv.lock` | Pinned Python dependencies |
| `.python-version` | Python version uv uses (3.12) |
| `uv-env.sh` | Sourced helper that points `UV_PROJECT_ENVIRONMENT` at the per-machine venv `.venv-<hostname>` |
