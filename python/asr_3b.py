"""ASR offline 3B — MlxTranslate.

Transcrit une vidéo (ou audio) en fenêtres (20 s par défaut) avec le modèle
Voxtral Mini 3B (mzbac/voxtral-mini-3b-4bit-mixed), forçant la langue via le
prompt `lang:<lang>` (mécanisme de l'ancien outil Python). Sort un JSON
compatible avec le nouvel outil (liste de textes par fenêtre).

Usage (appelé par l'outil Swift, ou seul) :
    python asr_3b.py --video <video|audio> --out <out.json> \
        [--window 20] [--lang ja] [--hf-home <dir>] [--model <repo>]

Le modèle + la librairie mlx_voxtral doivent être dispo dans
l'interpréteur Python courant ; HF_HOME pointe sur le cache du modèle.
"""
import argparse
import json
import os
import subprocess
import sys
import time
import wave

import numpy as np


def set_hf_env(hf_home: str | None) -> None:
    if hf_home:
        os.environ["HF_HOME"] = hf_home
        os.environ["TRANSFORMERS_CACHE"] = hf_home
    # Le modèle est local : pas de réseau.
    os.environ.setdefault("HF_HUB_OFFLINE", "1")


def extract_audio_16k(src: str, dst: str) -> None:
    subprocess.run(
        ["ffmpeg", "-y", "-loglevel", "error", "-i", src,
         "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", dst],
        check=True,
    )


def main() -> int:
    p = argparse.ArgumentParser(description="ASR offline 3B (Voxtral Mini 3B)")
    p.add_argument("--video", required=True, help="fichier vidéo ou audio")
    p.add_argument("--out", required=True, help="fichier JSON de sortie")
    p.add_argument("--window", type=int, default=20, help="durée des fenêtres (s)")
    p.add_argument("--lang", default="ja", help="langue forcée (défaut ja)")
    p.add_argument("--hf-home", default=None, help="cache HuggingFace du modèle")
    p.add_argument("--model", default="mzbac/voxtral-mini-3b-4bit-mixed")
    args = p.parse_args()

    set_hf_env(args.hf_home)

    # 1. Audio 16 kHz mono
    wav = "/tmp/mlxtranslate_3b_audio16k.wav"
    extract_audio_16k(args.video, wav)
    with wave.open(wav, "rb") as w:
        sr = w.getframerate()
        frames = w.readframes(w.getnframes())
        samples = np.frombuffer(frames, dtype=np.int16).astype(np.float32) / 32768.0
    n_windows = (len(samples) + sr * args.window - 1) // (sr * args.window)
    print(f"[3b] audio {len(samples)/sr:.0f}s -> {n_windows} fenêtres de {args.window}s",
          file=sys.stderr, flush=True)

    # 2. Charger le modèle 3B (mlx_voxtral)
    from mlx_voxtral import VoxtralForConditionalGeneration, VoxtralProcessor
    t0 = time.time()
    model = VoxtralForConditionalGeneration.from_pretrained(args.model)
    proc = VoxtralProcessor.from_pretrained(args.model)
    t_load = time.time() - t0
    print(f"[3b] chargement modèle {t_load:.1f}s", file=sys.stderr, flush=True)

    # 3. Transcrire chaque fenêtre (forçage langue dans le prompt)
    def decode(tokens):
        if hasattr(proc, "decode"):
            return proc.decode(tokens, skip_special_tokens=True)
        return proc.tokenizer.decode(tokens, skip_special_tokens=True)

    texts = []
    for i in range(n_windows):
        start = i * args.window * sr
        end = min(start + args.window * sr, len(samples))
        seg = samples[start:end]
        inputs = proc.apply_transcrition_request(language=args.lang, audio=seg)
        outputs = model.generate(
            input_ids=inputs.input_ids,
            input_features=inputs.input_features,
            max_new_tokens=1024,
            temperature=0.0,
        )
        new_tokens = outputs[0][inputs.input_ids.shape[1]:].tolist()
        texts.append(decode(new_tokens).strip())
        print(f"[3b] fenêtre {i+1}/{n_windows}", file=sys.stderr, flush=True)

    t_total = time.time() - t0
    json.dump(
        {
            "model": args.model,
            "lang": args.lang,
            "window": args.window,
            "load_s": round(t_load, 1),
            "total_s": round(t_total, 1),
            "texts": texts,
        },
        open(args.out, "w", encoding="utf-8"),
        ensure_ascii=False,
    )
    print(f"[3b] FINI {n_windows} fenêtres en {t_total:.1f}s -> {args.out}",
          file=sys.stderr, flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
