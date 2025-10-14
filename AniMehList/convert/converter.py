#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import argparse
import json
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Any, Dict, List, Optional

ROMAN_MAP = {
    "II": 2,
    "III": 3,
    "IV": 4,
    "V": 5,
    "VI": 6,
    "VII": 7,
    "VIII": 8,
    "IX": 9,
    "X": 10,
}

# Compile regexes once
RE_S_OR_SEASON_NUM = re.compile(r"\bS(?:eason)?\s*([0-9]{1,2})\b", re.IGNORECASE)
RE_ORDINAL_SEASON = re.compile(r"\b([0-9]{1,2})(?:st|nd|rd|th)\s+Season\b", re.IGNORECASE)
RE_SEASON_NUM = re.compile(r"\bSeason\s*([0-9]{1,2})\b", re.IGNORECASE)
RE_PART_NUM = re.compile(r"\bPart\s*([0-9]{1,2})\b", re.IGNORECASE)
RE_ROMAN = re.compile(r"\b(II|III|IV|V|VI|VII|VIII|IX|X)\b")
RE_TRAILING_NUM = re.compile(r"(\d{1,2})\s*$")

def safe_int(value: Optional[str], default: int = 0) -> int:
    try:
        if value is None:
            return default
        return int(value)
    except Exception:
        return default

def text(el: ET.Element, tag: str) -> Optional[str]:
    t = el.findtext(tag)
    if t is None:
        return None
    t = t.strip()
    return t if t != "" else None

def infer_season(series_title: str) -> Optional[int]:
    if not series_title:
        return None

    # S2 / Season 2
    m = RE_S_OR_SEASON_NUM.search(series_title)
    if m:
        try:
            n = int(m.group(1))
            return n
        except Exception:
            pass

    # 2nd Season
    m = RE_ORDINAL_SEASON.search(series_title)
    if m:
        try:
            n = int(m.group(1))
            return n
        except Exception:
            pass

    # Season 2 (alternate)
    m = RE_SEASON_NUM.search(series_title)
    if m:
        try:
            n = int(m.group(1))
            return n
        except Exception:
            pass

    # Part 2 (not always equal to season, but often used that way in titles)
    m = RE_PART_NUM.search(series_title)
    if m:
        try:
            n = int(m.group(1))
            return n
        except Exception:
            pass

    # Roman numerals like II, III, IV...
    m = RE_ROMAN.search(series_title)
    if m:
        token = m.group(1)
        if token in ROMAN_MAP:
            return ROMAN_MAP[token]

    # Trailing small number like "One Punch Man 3"
    m = RE_TRAILING_NUM.search(series_title)
    if m:
        try:
            n = int(m.group(1))
            # Heuristic: only treat small trailing numbers as season indices
            if 1 <= n <= 10:
                return n
        except Exception:
            pass

    return None

def map_kind(series_type: Optional[str]) -> str:
    if series_type and series_type.strip().lower() == "movie":
        return "MOVIE"
    return "SERIES"

def map_status(mal_status: Optional[str], is_rewatching: bool) -> str:
    if is_rewatching:
        return "REWATCH"
    if not mal_status:
        return "PLAN"
    s = mal_status.strip().lower()
    if s == "watching":
        return "WATCHING"
    if s == "completed":
        return "COMPLETED"
    if s == "plan to watch":
        return "PLAN"
    if s == "on-hold":
        return "WAITING"
    if s == "dropped":
        # We don't have DROPPED in the target schema; caller can choose to exclude or include as PLAN
        return "PLAN"
    return "PLAN"

def split_tags(raw: Optional[str]) -> List[str]:
    if not raw:
        return []
    # MAL tags are usually comma-separated
    parts = [t.strip() for t in raw.split(",")]
    return [p for p in parts if p]

def build_item(
    anime_el: ET.Element,
    include_dropped: bool,
    infer_season_flag: bool,
) -> Optional[Dict[str, Any]]:
    series_title = text(anime_el, "series_title") or ""
    series_type = text(anime_el, "series_type")  # TV, Movie, OVA, ONA, Special, TV Special, etc.
    kind = map_kind(series_type)

    mal_status = text(anime_el, "my_status")  # Watching, Completed, Plan to Watch, On-Hold, Dropped
    is_rewatching = safe_int(text(anime_el, "my_rewatching"), 0) == 1
    rewatch_ep = safe_int(text(anime_el, "my_rewatching_ep"), 0)
    watched_eps = safe_int(text(anime_el, "my_watched_episodes"), 0)
    score = safe_int(text(anime_el, "my_score"), 0)
    tags = split_tags(text(anime_el, "my_tags"))
    mal_id = text(anime_el, "series_animedb_id")

    # Handle dropping excluded items
    if mal_status and mal_status.strip().lower() == "dropped" and not include_dropped:
        return None

    status = map_status(mal_status, is_rewatching)

    # Episode logic
    episode: Optional[int] = None
    if status in ("WATCHING", "REWATCH"):
        episode = rewatch_ep if status == "REWATCH" else watched_eps
        # Normalize to None if zero (optional)
        if episode == 0:
            episode = None

    # Season inference
    season: Optional[int] = None
    if infer_season_flag:
        season = infer_season(series_title)

    # Notes
    notes_parts: List[str] = []
    if mal_status and mal_status.strip().lower() == "on-hold":
        notes_parts.append("MAL: On-Hold")
    if mal_status and mal_status.strip().lower() == "dropped":
        notes_parts.append("MAL: Dropped")
    # Add MAL type if it’s not TV or Movie (e.g., OVA, ONA, Special, TV Special)
    if series_type and series_type not in ("TV", "Movie"):
        notes_parts.append(f"MAL type: {series_type}")
    # If you want the MAL ID in notes, uncomment this:
    # if mal_id:
    #     notes_parts.append(f"MAL ID: {mal_id}")

    notes: Optional[str] = " | ".join(notes_parts) if notes_parts else None

    item: Dict[str, Any] = {
        "title": series_title,
        "kind": kind,
        "status": status,
        "season": season,
        "episode": episode,
        "absolute_episode": None,  # keep None by default; change if you want absolute progress mirrored
        "notes": notes,
        "tags": tags,
        "rating": None if score == 0 else score,
        "cover_url": None,
        "banner_key": None,
        "image_url": None,
    }
    return item

def convert_mal_xml_to_app_json(
    input_path: Path,
    output_path: Path,
    include_dropped: bool = False,
    infer_season_flag: bool = True,
) -> List[Dict[str, Any]]:
    tree = ET.parse(str(input_path))
    root = tree.getroot()

    items: List[Dict[str, Any]] = []

    for anime in root.findall("anime"):
        item = build_item(anime, include_dropped=include_dropped, infer_season_flag=infer_season_flag)
        if item is not None:
            items.append(item)

    # Write JSON
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with output_path.open("w", encoding="utf-8") as f:
        json.dump(items, f, ensure_ascii=False, indent=2)

    return items

def main():
    parser = argparse.ArgumentParser(
        description="Convert a MAL XML export to the app's JSON format."
    )
    parser.add_argument("input_xml", type=Path, help="Path to MAL XML export")
    parser.add_argument("output_json", type=Path, help="Path to write JSON")
    parser.add_argument(
        "--include-dropped",
        action="store_true",
        help="Include MAL entries with status Dropped (mapped to PLAN, notes include 'MAL: Dropped').",
    )
    parser.add_argument(
        "--no-infer-season",
        action="store_true",
        help="Disable season inference from titles.",
    )

    args = parser.parse_args()

    try:
        convert_mal_xml_to_app_json(
            input_path=args.input_xml,
            output_path=args.output_json,
            include_dropped=args.include_dropped,
            infer_season_flag=not args.no_infer_season,
        )
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)

    print(f"Wrote {args.output_json}")

if __name__ == "__main__":
    main()