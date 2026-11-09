#!/usr/bin/env python3
"""
kokoro-batch.py — speak a batch of text files with the official Kokoro TTS (hexgrad).

This is the engine behind tts.sh, the kocreator TTS plugin in this folder.  It
loads the model once and then speaks every job in the batch, so the slow part
(importing torch/spaCy and loading the weights) is paid once per run rather
than once per clip.  A single clip is simply a batch of one.

The jobs file has one job per line, three tab-separated fields:

    <input.txt> TAB <output.wav> TAB <seed, or empty>

After writing each output it prints "KOCREATOR_DONE <n>" (n = the 1-based job
number) on its own line, which is how kocreator tracks progress.  Kokoro is
deterministic, so a seed is noted and ignored.

Uses misaki G2P, which supports inline phonetic overrides with the
[word](/phonemes/) syntax.

Usage:
    uv run kokoro-batch.py jobs.tsv --voice am_liam --speed 1.0

Source: https://github.com/hexgrad/kokoro
"""

import argparse
import os
import sys
import time

# Each line goes out as soon as it's printed, so kocreator sees every
# KOCREATOR_DONE marker (and the log lines before it) in order and on time.
sys.stdout.reconfigure(line_buffering=True)

# Force fully offline mode — never contact HuggingFace Hub.
# Model and voice files must already be cached (downloaded during setup.sh).
os.environ['HF_HUB_OFFLINE'] = '1'

# kocreator passes its CPU thread budget in KOCREATOR_THREADS (and caps the
# OpenMP/MKL/BLAS pools through their own env vars). torch needs an explicit
# call as well, made before the model loads.
_threads = os.environ.get('KOCREATOR_THREADS', '')
if _threads.isdigit() and int(_threads) > 0:
    import torch
    torch.set_num_threads(int(_threads))
    torch.set_num_interop_threads(int(_threads))

import numpy as np
import soundfile as sf
from kokoro import KPipeline

DONE_MARKER = 'KOCREATOR_DONE'
SAMPLE_RATE = 24000

# Voice prefix -> language code mapping
# American English voices start with a (af_, am_), British with b (bf_, bm_)
LANG_CODE_MAP = {
    'a': 'a',  # American English
    'b': 'b',  # British English
    'e': 'e',  # Spanish
    'f': 'f',  # French
    'h': 'h',  # Hindi
    'i': 'i',  # Italian
    'j': 'j',  # Japanese
    'p': 'p',  # Portuguese
    'z': 'z',  # Mandarin Chinese
}


def detect_lang_code(voice: str) -> str:
    """Detect language code from voice name prefix."""
    if voice and len(voice) >= 2:
        first_char = voice[0]
        if first_char in LANG_CODE_MAP:
            return LANG_CODE_MAP[first_char]
    return 'a'


def read_jobs(path: str) -> list[tuple[str, str, str]]:
    """Parse the jobs file into (input, output, seed) tuples."""
    try:
        with open(path, 'r', encoding='utf-8') as f:
            lines = f.read().splitlines()
    except FileNotFoundError:
        print(f"Error: jobs file not found: {path}", file=sys.stderr)
        sys.exit(2)

    jobs = []
    for number, line in enumerate(lines, start=1):
        fields = line.split('\t')
        if len(fields) != 3 or not fields[0] or not fields[1]:
            print(f"Error: {path} line {number}: expected input<TAB>output<TAB>seed, "
                  f"got {line!r}", file=sys.stderr)
            sys.exit(2)
        jobs.append((fields[0], fields[1], fields[2]))
    if not jobs:
        print(f"Error: jobs file is empty: {path}", file=sys.stderr)
        sys.exit(2)
    return jobs


def speak(pipeline: KPipeline, text: str, voice: str, speed: float):
    """Return the audio for *text*, or None if Kokoro produced nothing."""
    audio_chunks = [
        audio
        for _gs, _ps, audio in pipeline(text, voice=voice, speed=speed, split_pattern=r'\n+')
    ]
    return np.concatenate(audio_chunks) if audio_chunks else None


def main():
    parser = argparse.ArgumentParser(
        description='Speak a batch of text files with official Kokoro TTS (hexgrad)')
    parser.add_argument('jobs', help='Jobs file: input<TAB>output<TAB>seed per line')
    parser.add_argument('--voice', default='am_liam',
                        help='Voice name (default: am_liam)')
    parser.add_argument('--speed', type=float, default=1.0,
                        help='Speech speed (default: 1.0)')
    parser.add_argument('--lang', default=None,
                        help='Language code override (auto-detected from voice if omitted)')
    args = parser.parse_args()

    jobs = read_jobs(args.jobs)

    started = time.perf_counter()
    lang_code = args.lang if args.lang else detect_lang_code(args.voice)
    pipeline = KPipeline(lang_code=lang_code)
    print(f"Loaded Kokoro (voice {args.voice}) in {time.perf_counter() - started:.1f}s; "
          f"speaking {len(jobs)} job(s)")

    for number, (input_path, output_path, seed) in enumerate(jobs, start=1):
        print(f"[{number}/{len(jobs)}] {input_path}")
        if seed:
            print(f"Note: Kokoro is deterministic and has no seed; ignoring seed {seed}.")
        try:
            with open(input_path, 'r', encoding='utf-8') as f:
                text = f.read().strip()
        except FileNotFoundError:
            print(f"Error: input file not found: {input_path}", file=sys.stderr)
            sys.exit(1)
        if not text:
            print(f"Error: input file is empty: {input_path}", file=sys.stderr)
            sys.exit(1)

        audio = speak(pipeline, text, args.voice, args.speed)
        if audio is None:
            print(f"Error: no audio generated for {input_path}", file=sys.stderr)
            sys.exit(1)

        sf.write(output_path, audio, SAMPLE_RATE)
        print(f"Generated {output_path} ({len(audio) / SAMPLE_RATE:.1f}s)")
        print(f"{DONE_MARKER} {number}")


if __name__ == '__main__':
    main()
