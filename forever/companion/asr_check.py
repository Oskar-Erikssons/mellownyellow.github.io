#!/usr/bin/env python3
"""Listens to voice clips with a speech recognition model and flags the ones that are hard to understand.

Made for KlangAI/pianissimo-sv (Swedish, CC BY 4.0, a fine-tune of NVIDIA Parakeet TDT 0.6B v3).
It turns speech into text, so it cannot read anything aloud; here it checks that a voice did.
For each clip it compares what it heard with the text that should have been spoken
(character error rate, CER). A high CER means mumbling, skipped words or a wrong language.

Runs locally with the ONNX version of the model through the onnx-asr package:
    pip install onnx-asr
    huggingface-cli download KlangAI/pianissimo-sv-onnx --local-dir models/pianissimo-sv

    python asr_check.py --model models/pianissimo-sv --clips ../addon/ForeverGuide_Voices/sounds --texts texts.json
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import unicodedata
from pathlib import Path


def normalize(text: str) -> str:
    text = unicodedata.normalize("NFC", text.lower())
    text = re.sub(r"[^\w\s]", " ", text)
    return re.sub(r"\s+", " ", text).strip()


def cer(reference: str, heard: str) -> float:
    """Character error rate: edits needed to turn what was heard into the reference, per reference character."""
    a, b = normalize(reference), normalize(heard)
    if not a:
        return 0.0 if not b else 1.0
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1] / len(a)


class Recognizer:
    def __init__(self, model_dir: Path, model_type: str = "nemo-parakeet-tdt-0.6b-v3"):
        import onnx_asr  # pip install onnx-asr
        self.model = onnx_asr.load_model(model_type, str(model_dir))

    def __call__(self, wav_path: Path) -> str:
        return self.model.recognize(str(wav_path))


def check(clips: dict[str, Path], texts: dict[str, str], hear, limit: float) -> list[dict]:
    rows = []
    for key, path in sorted(clips.items()):
        if key not in texts:
            continue
        heard = hear(path)
        rows.append({"key": key, "cer": round(cer(texts[key], heard), 3), "heard": heard, "text": texts[key],
                     "ok": cer(texts[key], heard) <= limit})
    return sorted(rows, key=lambda r: -r["cer"])


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--model", type=Path, required=True, help="Folder with the ONNX speech recognition model")
    ap.add_argument("--clips", type=Path, required=True, help="Folder with .ogg or .wav clips")
    ap.add_argument("--texts", type=Path, required=True, help="JSON {clip key: spoken text}, written by forever_voice.py")
    ap.add_argument("--limit", type=float, default=0.15, help="Highest CER that still counts as clear speech")
    ap.add_argument("--out", type=Path, default=Path("asr_report.json"))
    args = ap.parse_args(argv)
    clips = {p.stem: p for p in args.clips.iterdir() if p.suffix in (".ogg", ".wav")}
    texts = json.loads(args.texts.read_text(encoding="utf-8"))
    rows = check(clips, texts, Recognizer(args.model), args.limit)
    args.out.write_text(json.dumps(rows, ensure_ascii=False, indent=2), encoding="utf-8")
    bad = [r for r in rows if not r["ok"]]
    print(f"Checked {len(rows)} clips: {len(rows) - len(bad)} clear, {len(bad)} unclear (CER > {args.limit}).")
    for r in bad[:20]:
        print(f"  {r['key']}  CER {r['cer']:.2f}  heard: {r['heard'][:70]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
