#!/usr/bin/env python3
"""Forever Guide companion: turns queued quest texts into voice clips.

The addon saves every text it could not voice to ForeverGuideDB.voiceQueue
(in WTF/Account/<ACCOUNT>/SavedVariables/ForeverGuide.lua) when you log out.
This script reads that queue, speaks each text with an open-source TTS model
and writes .ogg files plus Manifest.lua into the ForeverGuide_Voices addon.
Restart the game afterwards so the client sees the new files.

The script only reads SavedVariables and writes addon files. It never touches
the running game.

Examples:
    python forever_voice.py --wow "C:/Program Files (x86)/World of Warcraft/_forever_" --dry-run
    python forever_voice.py --wow "..." --engine kokoro
    python forever_voice.py --wow "..." --engine chatterbox --voices voices.json
    python forever_voice.py --wow "..." --engine http --url http://gpu-box:8080/v1 --model drama-3

The http engine reads an optional API key from the TTS_API_KEY environment variable.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import zlib
from pathlib import Path

import numpy as np

import lua_table

SAMPLE_RATE = 24000


# --- Voice choice --------------------------------------------------------------

KOKORO_VOICES = {
    "male": ["am_michael", "bm_george", "am_fenrir", "bm_lewis", "am_onyx", "bm_daniel", "am_puck"],
    "female": ["af_heart", "bf_emma", "af_bella", "bf_isabella", "af_nicole", "af_sarah", "bf_alice"],
    "narrator": "bm_fable",
}


def pick(pool: list[str], name: str | None) -> str:
    """Same NPC name always gets the same voice from the pool."""
    if not name:
        return pool[0]
    return pool[zlib.crc32(name.encode("utf-8")) % len(pool)]


def choose_voice(entry: dict, config: dict, defaults: dict) -> str:
    npc = entry.get("npc")
    overrides = config.get("npc", {})
    if npc and npc in overrides:
        return overrides[npc]
    # Quest log, books and pre-made zone packs have no NPC, so the narrator reads them.
    if entry.get("kind") in ("log", "book") or not npc:
        return config.get("narrator", defaults["narrator"])
    sex = "female" if entry.get("sex") == 3 else "male"
    return pick(config.get(sex, defaults[sex]), npc)


# --- Text cleanup --------------------------------------------------------------

def fill_template(text: str, player: str = "adventurer") -> str:
    """Quest placeholders: $N name, $C class, $R race, $G male:female; and $B line break.

    The addon stores your name as $N, so one clip works for every character."""
    text = re.sub(r"\$[Gg]\s*([^:;]*):([^;]*);", r"\1", text)
    text = re.sub(r"\$[Nn]", player, text)
    text = re.sub(r"\$[Cc]", "adventurer", text)
    text = re.sub(r"\$[Rr]", "traveler", text)
    return re.sub(r"\$[Bb]", " ", text)


def tts_text(text: str, player: str = "adventurer") -> str:
    text = fill_template(text, player)
    text = re.sub(r"<[^>]*>", " ", text)          # emotes like <The dwarf laughs.>
    text = text.replace("|n", " ")
    text = re.sub(r"\s+", " ", text).strip()
    return text


def sentences(text: str, max_chars: int = 300) -> list[str]:
    """Split long texts so models with short context windows keep quality."""
    parts = re.split(r"(?<=[.!?])\s+", text)
    chunks, cur = [], ""
    for p in parts:
        if cur and len(cur) + len(p) + 1 > max_chars:
            chunks.append(cur)
            cur = p
        else:
            cur = f"{cur} {p}".strip()
    if cur:
        chunks.append(cur)
    return chunks


# --- Engines -----------------------------------------------------------------

class TestEngine:
    """Short tone per sentence. Tests the whole pipeline without a model."""

    name = "test"
    defaults = {"male": ["low"], "female": ["high"], "narrator": "mid"}

    def speak(self, text: str, voice: str) -> np.ndarray:
        freq = {"low": 180.0, "mid": 260.0, "high": 340.0}.get(voice, 260.0)
        out = []
        for chunk in sentences(text):
            t = np.linspace(0, min(2.0, 0.04 * len(chunk)), int(SAMPLE_RATE * min(2.0, 0.04 * len(chunk))), endpoint=False)
            out += [0.2 * np.sin(2 * np.pi * freq * t), np.zeros(SAMPLE_RATE // 5)]
        return np.concatenate(out).astype(np.float32)


class KokoroEngine:
    """Kokoro-82M (Apache-2.0). Fast, runs well on CPU, English voices."""

    name = "kokoro"
    defaults = KOKORO_VOICES

    def __init__(self):
        from kokoro import KPipeline  # pip install kokoro soundfile
        self._pipelines = {}
        self._make = KPipeline

    def speak(self, text: str, voice: str) -> np.ndarray:
        lang = voice[0]  # "a" = American, "b" = British voices
        if lang not in self._pipelines:
            self._pipelines[lang] = self._make(lang_code=lang)
        audio = [np.asarray(a, dtype=np.float32) for _, _, a in self._pipelines[lang](text, voice=voice)]
        return np.concatenate(audio)


class ChatterboxEngine:
    """Chatterbox (MIT, Resemble AI). Voice cloning from a short reference clip
    and an "exaggeration" knob for dramatic NPCs. Best quality, wants a GPU.

    A voice is a path to a 5-15 second .wav reference, or "default".
    """

    name = "chatterbox"
    defaults = {"male": ["default"], "female": ["default"], "narrator": "default"}

    def __init__(self, exaggeration: float = 0.6):
        import torch
        from chatterbox.tts import ChatterboxTTS  # pip install chatterbox-tts
        device = "cuda" if torch.cuda.is_available() else ("mps" if torch.backends.mps.is_available() else "cpu")
        self.model = ChatterboxTTS.from_pretrained(device=device)
        self.exaggeration = exaggeration

    def speak(self, text: str, voice: str) -> np.ndarray:
        prompt = None if voice == "default" else voice
        out = []
        for chunk in sentences(text):
            wav = self.model.generate(chunk, audio_prompt_path=prompt, exaggeration=self.exaggeration)
            out.append(wav.squeeze(0).cpu().numpy().astype(np.float32))
        audio = np.concatenate(out)
        if self.model.sr != SAMPLE_RATE:
            audio = resample(audio, self.model.sr, SAMPLE_RATE)
        return audio


class HttpEngine:
    """Any server with an OpenAI-style POST /audio/speech endpoint.

    Use it for models that are too big to load in this script, for example
    Fish Audio Drama 3 (35B, open weights) on a rented GPU, Kokoro-FastAPI on
    your own computer, or a hosted endpoint such as OpenRouter.
    A voice is the server's voice name or ID.

    Drama 3 takes acting notes in square brackets. Put them in the voices
    file under "prefix", per text kind, e.g. {"gossip": "[warm, friendly]"}.
    """

    name = "http"
    defaults = {"male": ["default"], "female": ["default"], "narrator": "default"}

    def __init__(self, url: str, model: str, api_key: str | None, response_format: str = "wav"):
        import requests
        self.session = requests.Session()
        if api_key:
            self.session.headers["Authorization"] = f"Bearer {api_key}"
        self.url = url.rstrip("/") + "/audio/speech"
        self.model = model
        self.format = response_format

    def speak(self, text: str, voice: str) -> np.ndarray:
        import io
        import soundfile as sf
        body = {"model": self.model, "input": text, "response_format": self.format}
        if voice != "default":
            body["voice"] = voice
        r = self.session.post(self.url, json=body, timeout=600)
        r.raise_for_status()
        audio, sr = sf.read(io.BytesIO(r.content), dtype="float32")
        if audio.ndim > 1:
            audio = audio.mean(axis=1)
        return resample(audio, sr, SAMPLE_RATE) if sr != SAMPLE_RATE else audio


def resample(audio: np.ndarray, src: int, dst: int) -> np.ndarray:
    n = int(len(audio) * dst / src)
    return np.interp(np.linspace(0, len(audio) - 1, n), np.arange(len(audio)), audio).astype(np.float32)


ENGINES = {"test": TestEngine, "kokoro": KokoroEngine, "chatterbox": ChatterboxEngine, "http": HttpEngine}


# --- Files -----------------------------------------------------------------

def find_saved_variables(wow: Path) -> list[Path]:
    return sorted(wow.glob("WTF/Account/*/SavedVariables/ForeverGuide.lua"))


def read_queue(files: list[Path]) -> dict[str, dict]:
    queue: dict[str, dict] = {}
    for f in files:
        db = lua_table.load(f).get("ForeverGuideDB") or {}
        for key, entry in (db.get("voiceQueue") or {}).items():
            if isinstance(entry, dict) and entry.get("text"):
                queue[str(key)] = entry
    return queue


def quest_entries(path: Path, zone: int | None, min_level: int, max_level: int) -> dict[str, dict]:
    """Turns quests.json (from quest_db.py) into queue entries with the addon's keys."""
    entries = {}
    for q in json.loads(path.read_text(encoding="utf-8")):
        level = q.get("level") or q.get("minLevel") or 0
        if zone is not None and q.get("zone") != zone:
            continue
        if level and not (min_level <= level <= max_level):
            continue
        detail = f"{q['title']}. {q.get('details') or ''} {q.get('objectives') or ''}".strip()
        for kind, text in (("detail", detail), ("progress", q.get("progress")), ("complete", q.get("complete"))):
            if text and text.strip():
                entries[f"{kind[0]}{q['id']}"] = {"kind": kind, "text": text, "quest": q["id"], "npc": None}
    return entries


def write_manifest(addon_dir: Path) -> int:
    import soundfile as sf
    sounds = sorted((addon_dir / "sounds").glob("*.ogg"))
    lines = [
        "-- Generated by companion/forever_voice.py. Do not edit by hand.",
        "-- key = length of the clip in seconds",
        "ForeverGuideVoices = {",
    ]
    for p in sounds:
        info = sf.info(str(p))
        lines.append(f"    [{lua_table.lua_string(p.stem)}] = {info.duration:.2f},")
    lines.append("}")
    (addon_dir / "Manifest.lua").write_text("\n".join(lines) + "\n", encoding="utf-8")
    return len(sounds)


def save_ogg(path: Path, audio: np.ndarray):
    import soundfile as sf
    peak = float(np.max(np.abs(audio))) if audio.size else 0.0
    if peak > 0.99:
        audio = audio / peak * 0.99
    sf.write(str(path), audio, SAMPLE_RATE, format="OGG", subtype="VORBIS")


# --- Main --------------------------------------------------------------------

def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--wow", type=Path, help="Game folder, e.g. .../World of Warcraft/_forever_")
    ap.add_argument("--saved", type=Path, nargs="*", help="ForeverGuide.lua SavedVariables file(s), if not using --wow")
    ap.add_argument("--addon", type=Path, help="ForeverGuide_Voices folder, if not using --wow")
    ap.add_argument("--engine", choices=sorted(ENGINES), default="kokoro")
    ap.add_argument("--voices", type=Path, help="JSON with voice choices (see voices.example.json)")
    ap.add_argument("--exaggeration", type=float, default=0.6, help="Chatterbox emotion, 0.25-2.0")
    ap.add_argument("--url", help="http engine: server base URL, e.g. http://localhost:8880/v1")
    ap.add_argument("--model", default="tts-1", help="http engine: model name, e.g. fish-audio/drama-3")
    ap.add_argument("--format", default="wav", help="http engine: audio format to ask for (wav, mp3)")
    ap.add_argument("--quests", type=Path, help="quests.json from quest_db.py: voice quests before you meet them")
    ap.add_argument("--zone", type=int, help="With --quests: only this zone ID")
    ap.add_argument("--min-level", type=int, default=1)
    ap.add_argument("--max-level", type=int, default=60)
    ap.add_argument("--player-word", default="adventurer", help="Spoken instead of your name")
    ap.add_argument("--limit", type=int, default=0, help="Voice at most this many texts")
    ap.add_argument("--dry-run", action="store_true", help="Only list what would be voiced")
    args = ap.parse_args(argv)

    if args.saved:
        files = args.saved
    elif args.wow:
        files = find_saved_variables(args.wow)
    else:
        ap.error("give --wow or --saved")
    if args.quests:
        files = files or []
    addon_dir = args.addon or (args.wow / "Interface" / "AddOns" / "ForeverGuide_Voices" if args.wow else None)
    if not addon_dir:
        ap.error("give --wow or --addon")
    if not files and not args.quests:
        print("No ForeverGuide.lua found. Log in with the addon, read a quest and log out first.")
        return 1

    queue = read_queue(files)
    if args.quests:
        queue.update(quest_entries(args.quests, args.zone, args.min_level, args.max_level))
    sound_dir = addon_dir / "sounds"
    todo = {k: v for k, v in queue.items() if not (sound_dir / f"{k}.ogg").exists()}
    if args.limit:
        todo = dict(list(todo.items())[: args.limit])
    print(f"{len(queue)} queued texts, {len(todo)} need a voice.")

    config = json.loads(args.voices.read_text(encoding="utf-8")).get(args.engine, {}) if args.voices else {}
    engine_cls = ENGINES[args.engine]

    if args.dry_run:
        for key, entry in todo.items():
            voice = choose_voice(entry, config, engine_cls.defaults)
            print(f"{key} [{voice}] {entry.get('npc') or '-'}: {tts_text(entry['text'], args.player_word)[:90]}")
        return 0

    if args.engine == "chatterbox":
        engine = engine_cls(args.exaggeration)
    elif args.engine == "http":
        if not args.url:
            ap.error("the http engine needs --url")
        engine = engine_cls(args.url, args.model, os.environ.get("TTS_API_KEY"), args.format)
    else:
        engine = engine_cls()
    prefixes = config.get("prefix", {})
    sound_dir.mkdir(parents=True, exist_ok=True)
    for n, (key, entry) in enumerate(todo.items(), 1):
        voice = choose_voice(entry, config, engine_cls.defaults)
        text = tts_text(entry["text"], args.player_word)
        if prefixes.get(entry.get("kind")):
            text = f"{prefixes[entry['kind']]} {text}"
        print(f"[{n}/{len(todo)}] {key} ({voice}) {text[:60]}")
        try:
            save_ogg(sound_dir / f"{key}.ogg", engine.speak(text, voice))
        except Exception as exc:  # one bad text should not stop the batch
            print(f"  failed: {exc}", file=sys.stderr)

    count = write_manifest(addon_dir)
    print(f"Manifest.lua lists {count} clips. Restart the game to hear the new voices.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
