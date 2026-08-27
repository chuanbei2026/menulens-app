#!/usr/bin/env python3
"""Re-translate a bundled sample scan into another app language.

Why not just re-run the app's pipeline? Because the pipeline re-derives the
whole page: OCR line inventory, sectioning, dish grouping. A fresh run would
renumber the dish keys (`p<page>_s<section>_i<item>`), and the 30-41 baked
dish thumbnails filed under those keys would all point at the wrong dishes.

So this rewrites ONLY the translated fields, from the ORIGINALS (never from
an existing translation — translating a translation degrades names), and
leaves every bbox, line index and dish key untouched. The existing
gen_<dishKey>.jpg thumbnails stay valid.

Two invariants the renderer depends on, both enforced here:

  * A text line whose `translated` is "" means "keep the original as
    printed" (prices, logos, brand text). Those stay "".
  * A `dish_name` line's translation is the dish's translated name ALONE —
    no price, no [GF]/[VG] codes, even though the printed line carries them.
    The canvas paints that translation over the name strip and draws the
    price separately from `price`, so leaving the price in would print it
    twice. Same for `section_title` lines and section titles.

    These two line roles are therefore NOT sent to the model at all: they
    are derived from the dish/section translation by matching the line's
    original text against the dish/section original. Validated against the
    already-shipped Chinese samples: 93 lines matched, 0 disagreements.

Usage:
    OPENAI_API_KEY=sk-... python3 tools/retarget_sample.py \
        --sample MenuLens/Resources/Samples/la-mar \
        --lang en --out MenuLens/Resources/Samples/en/la-mar
"""

import argparse
import json
import os
import pathlib
import re
import shutil
import sys
import urllib.error
import urllib.request
import uuid

ENDPOINT = "https://api.openai.com/v1/chat/completions"

# Mirrors AppLanguage in the app. Keep in sync.
LANGUAGES = {
    "zh-Hans": "Simplified Chinese",
    "en": "English",
    "ja": "Japanese",
    "ko": "Korean",
    "fr": "French",
    "es": "Spanish",
    "hi": "Hindi",
}


def api_key() -> str:
    if key := os.environ.get("OPENAI_API_KEY", "").strip():
        return key
    # Fall back to the gitignored review key, the only key in the repo tree.
    local = pathlib.Path("docs/review-key.local.md")
    if local.exists():
        if m := re.search(r"\bsk-[A-Za-z0-9_\-]{20,}", local.read_text()):
            return m.group(0)
    sys.exit("no API key: set OPENAI_API_KEY or put one in docs/review-key.local.md")


def collect(scan: dict) -> tuple[list[dict], list[dict], list[dict], dict[str, str]]:
    """Flatten the units needing translation, each tagged with its address.

    Returns (lines, sections, dishes, derived) where `derived` maps a line
    id to the dish/section id whose translation it must reuse verbatim.
    Those lines are deliberately absent from `lines`.
    """
    lines, sections, dishes, derived = [], [], [], {}
    for p, page in enumerate(scan["pages"]):
        # Address book for this page, longest original first so "Tikka
        # Masala" can never claim a line belonging to "Tikka Masala Deluxe".
        anchors: list[tuple[str, str]] = []
        for s, section in enumerate(page["sections"]):
            if (title := section.get("originalTitle") or "").strip():
                sections.append({"id": f"S{p}_{s}", "text": title})
                anchors.append((title.strip(), f"S{p}_{s}"))
            for it, item in enumerate(section["items"]):
                dishes.append({
                    "id": f"D{p}_{s}_{it}",
                    "name": item["originalName"],
                    "description": item.get("originalDescription") or "",
                })
                if item["originalName"].strip():
                    anchors.append((item["originalName"].strip(), f"D{p}_{s}_{it}"))
        anchors.sort(key=lambda a: -len(a[0]))

        for i, line in enumerate(page.get("textLines") or []):
            # "" means "leave as printed" — a decision made when the sample
            # was first baked, off the actual photo. Don't re-litigate it.
            if not line["translated"].strip():
                continue
            line_id = f"L{p}_{i}"
            if line["role"] in ("dish_name", "section_title"):
                original = line["original"].strip()
                anchor = next((a for text, a in anchors if original.startswith(text)), None)
                if anchor:
                    derived[line_id] = anchor
                    continue  # not the model's problem
            lines.append({"id": line_id, "role": line["role"], "text": line["original"]})
    return lines, sections, dishes, derived


def request_translations(key: str, model: str, target: str, source_language: str,
                         lines: list[dict], sections: list[dict], dishes: list[dict]) -> dict:
    payload_in = {
        "sourceLanguage": source_language,
        "sectionTitles": sections,
        "dishes": dishes,
        "textLines": lines,
    }
    system = f"""\
You are re-translating an already-analyzed restaurant menu into {target}. The \
page geometry is fixed and not your concern; you only replace text.

Rules:
1. Translate every entry into {target}, keyed by its `id`. Return every id you \
were given, exactly once.
2. Dish names: give the dish a name that stands on its own in {target}. When \
the printed name omits the dish type ("Clasico", "Limeno" on a cebiche menu), \
name the dish, don't transliterate. Never append the original name in \
parentheses.
3. A textLine whose role is `dish_name` or `section_title` is a NAME: give \
the name alone. Drop the price and any bracketed dietary codes ([GF], [VG]) \
the printed line happens to carry — those are drawn separately, and repeating \
them here prints them twice.
4. Never repeat or parenthesize the original text inside a translation.
5. Fix obvious OCR damage in the original before translating it (e.g. a stray \
"(fKg)" is noise, not an ingredient) — but never invent ingredients.
6. Also report `sourceLanguageName`: the name of the menu's own language \
({source_language}), written in {target}.
7. If the source text is already in {target}, still return a natural {target} \
rendering — for a dish name that means naming the dish plainly, and for a \
description it may be the same words.
8. Return EVERY id. Do not stop early and do not summarise — a dropped id \
leaves a hole in the menu.
"""
    entry = {
        "type": "object",
        "additionalProperties": False,
        "properties": {"id": {"type": "string"}, "text": {"type": "string"}},
        "required": ["id", "text"],
    }
    schema = {
        "type": "object",
        "additionalProperties": False,
        "properties": {
            "sourceLanguageName": {"type": "string"},
            "sectionTitles": {"type": "array", "items": entry},
            "dishes": {
                "type": "array",
                "items": {
                    "type": "object",
                    "additionalProperties": False,
                    "properties": {
                        "id": {"type": "string"},
                        "name": {"type": "string"},
                        "description": {"type": "string"},
                    },
                    "required": ["id", "name", "description"],
                },
            },
            "textLines": {"type": "array", "items": entry},
        },
        "required": ["sourceLanguageName", "sectionTitles", "dishes", "textLines"],
    }
    body = {
        "model": model,
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": json.dumps(payload_in, ensure_ascii=False)},
        ],
        "response_format": {
            "type": "json_schema",
            "json_schema": {"name": "retarget", "strict": True, "schema": schema},
        },
    }
    req = urllib.request.Request(
        ENDPOINT,
        data=json.dumps(body).encode(),
        headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=900) as response:
            result = json.load(response)
    except urllib.error.HTTPError as error:
        sys.exit(f"HTTP {error.code}: {error.read().decode()[:800]}")
    choice = result["choices"][0]["message"]
    if choice.get("refusal"):
        sys.exit(f"model refused: {choice['refusal']}")
    usage = result.get("usage", {})
    print(f"    tokens in={usage.get('prompt_tokens')} out={usage.get('completion_tokens')}")
    return json.loads(choice["content"])


def translate_all(key: str, model: str, target: str, source_language: str,
                  lines: list[dict], sections: list[dict], dishes: list[dict],
                  attempts: int = 3) -> dict:
    """Translate everything, asking again for whatever the model dropped.

    Models truncate the tail of a long list — observed on a 138-line menu
    that came back missing its last five lines while a 249-line one was
    complete, so this is not a context limit and a plain retry would just
    re-roll the dice. Each round asks only for the ids still missing, which
    also makes the follow-up request small and cheap.
    """
    merged = {"sourceLanguageName": "", "sectionTitles": [], "dishes": [], "textLines": []}
    pending_lines, pending_sections, pending_dishes = lines, sections, dishes
    for attempt in range(1, attempts + 1):
        if attempt > 1:
            print(f"    refill round {attempt}: {len(pending_lines)} lines, "
                  f"{len(pending_sections)} sections, {len(pending_dishes)} dishes")
        out = request_translations(key, model, target, source_language,
                                   pending_lines, pending_sections, pending_dishes)
        merged["sourceLanguageName"] = merged["sourceLanguageName"] or out["sourceLanguageName"]
        for field in ("sectionTitles", "dishes", "textLines"):
            merged[field].extend(out[field])
        got = {field: {e["id"] for e in merged[field]}
               for field in ("sectionTitles", "dishes", "textLines")}
        pending_lines = [u for u in lines if u["id"] not in got["textLines"]]
        pending_sections = [u for u in sections if u["id"] not in got["sectionTitles"]]
        pending_dishes = [u for u in dishes if u["id"] not in got["dishes"]]
        if not (pending_lines or pending_sections or pending_dishes):
            return merged
    dropped = pending_lines + pending_sections + pending_dishes
    sys.exit(f"still missing {len(dropped)} ids after {attempts} rounds: "
             f"{[u['id'] for u in dropped][:8]}")


def apply(scan: dict, out: dict, lang: str, derived: dict[str, str]) -> dict:
    """Write the translations back into a copy of the scan, in place."""
    line_map = {e["id"]: e["text"] for e in out["textLines"]}
    section_map = {e["id"]: e["text"] for e in out["sectionTitles"]}
    dish_map = {e["id"]: e for e in out["dishes"]}
    source_name = out["sourceLanguageName"]

    scan = json.loads(json.dumps(scan))  # deep copy
    scan["id"] = str(uuid.uuid4()).upper()
    scan["targetLanguage"] = lang
    scan["sourceLanguageChinese"] = source_name

    missing = []
    for p, page in enumerate(scan["pages"]):
        page["sourceLanguageChinese"] = source_name
        for s, section in enumerate(page["sections"]):
            key = f"S{p}_{s}"
            if key in section_map:
                section["chineseTitle"] = section_map[key]
            elif (section.get("originalTitle") or "").strip():
                missing.append(key)
            for it, item in enumerate(section["items"]):
                key = f"D{p}_{s}_{it}"
                if translated := dish_map.get(key):
                    item["chineseName"] = translated["name"]
                    # Keep null-vs-string shape: a dish with no printed
                    # description must not gain an empty one.
                    if (item.get("originalDescription") or "").strip():
                        item["chineseDescription"] = translated["description"]
                else:
                    missing.append(key)
        for i, line in enumerate(page.get("textLines") or []):
            if not line["translated"].strip():
                continue  # stays "" — renderer reads that as "keep as printed"
            key = f"L{p}_{i}"
            if anchor := derived.get(key):
                # Name lines reuse the dish/section translation verbatim.
                line["translated"] = (
                    section_map[anchor] if anchor.startswith("S")
                    else dish_map[anchor]["name"]
                )
            elif key in line_map:
                line["translated"] = line_map[key]
            else:
                missing.append(key)
    if missing:
        sys.exit(f"model dropped {len(missing)} ids, e.g. {missing[:8]}")
    return scan


def check(original: dict, new: dict, lang: str) -> None:
    """Structure must be identical — the baked thumbnails depend on it."""
    def shape(scan):
        return [
            [(len(s["items"]), len(p.get("textLines") or [])) for s in p["sections"]]
            for p in scan["pages"]
        ]

    assert shape(original) == shape(new), "structure changed — dish keys would shift"
    for p_old, p_new in zip(original["pages"], new["pages"]):
        for old, fresh in zip(p_old.get("textLines") or [], p_new.get("textLines") or []):
            assert old["box"] == fresh["box"], "line geometry changed"
            assert bool(old["translated"].strip()) == bool(fresh["translated"].strip()), \
                "a line changed between blank and non-blank"
    # Name lines must carry the name alone — a price surviving here would be
    # painted onto the canvas on top of the separately-drawn price.
    for p_new in new["pages"]:
        names = {i["chineseName"] for s in p_new["sections"] for i in s["items"]}
        names |= {s.get("chineseTitle") or "" for s in p_new["sections"]}
        for tl in (p_new.get("textLines") or []):
            if tl["role"] in ("dish_name", "section_title") and tl["translated"].strip():
                assert tl["translated"] in names or not any(
                    n and tl["translated"].startswith(n) for n in names
                ), f"name line carries extra text: {tl['translated']!r}"
    empty = [
        item["originalName"]
        for p in new["pages"] for s in p["sections"] for item in s["items"]
        if not item["chineseName"].strip()
    ]
    assert not empty, f"dishes left untranslated: {empty[:5]}"
    if lang != "zh-Hans":
        # Cheap smell test: Han characters left in a non-CJK target usually
        # means the model echoed the Chinese it was NOT given.
        han = re.compile(r"[一-鿿]")
        leaked = [
            item["chineseName"]
            for p in new["pages"] for s in p["sections"] for item in s["items"]
            if han.search(item["chineseName"])
        ]
        if leaked and lang not in ("ja", "ko"):
            print(f"    ⚠️  Han characters in {lang} output: {leaked[:5]}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--sample", required=True, help="source sample dir (with scan.json)")
    parser.add_argument("--lang", required=True, choices=sorted(LANGUAGES))
    parser.add_argument("--out", required=True, help="destination sample dir")
    parser.add_argument("--model", default="gpt-4.1")
    args = parser.parse_args()

    source = pathlib.Path(args.sample)
    scan = json.loads((source / "scan.json").read_text())
    target = LANGUAGES[args.lang]
    lines, sections, dishes, derived = collect(scan)
    print(f"  {source.name} -> {args.lang}: {len(lines)} lines to translate "
          f"(+{len(derived)} name lines derived locally), "
          f"{len(sections)} sections, {len(dishes)} dishes")

    out = translate_all(
        api_key(), args.model, target, scan.get("sourceLanguage", "unknown"),
        lines, sections, dishes,
    )
    new = apply(scan, out, args.lang, derived)
    check(scan, new, args.lang)

    destination = pathlib.Path(args.out)
    destination.mkdir(parents=True, exist_ok=True)
    # Photos and baked thumbnails are language-independent: same bytes, and
    # the dish keys they are filed under are unchanged.
    for asset in source.iterdir():
        if asset.name != "scan.json":
            shutil.copy2(asset, destination / asset.name)
    (destination / "scan.json").write_text(
        json.dumps(new, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    )
    first = new["pages"][0]["sections"][0]["items"][0]
    print(f"    ✓ {destination}  e.g. {first['originalName']!r} -> {first['chineseName']!r}")


if __name__ == "__main__":
    main()
