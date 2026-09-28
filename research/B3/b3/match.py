"""Match a YouTube video to the same episode in the podcast's own feed.

Two stages, because the confident-wrong failure that matters is "right
title, wrong show" or "right show, wrong episode":

1. Which show is this? Candidate shows come from Apple Podcasts links in the
   description, and from searching Apple's catalog for the channel name and
   for show-like parts of the title ("... | Lex Fridman Podcast #502"). A
   show counts as identified only when its name is backed by the channel
   name or the title, not merely by a search hit.
2. Which episode? The identified show's recent episodes (plus an episode
   search by title) are scored on episode number, title, description
   overlap, publish date and duration, as the Spotify resolver does.

A match is confident only when the show is identified, the durations agree
(a 10-minute clip never confidently matches a 3-hour episode), at least one
strong episode signal holds, and the runner-up is clearly behind. Anything
less is "review" with candidates, or "none".
"""
from __future__ import annotations

import datetime as dt
import re
from dataclasses import dataclass, field, asdict

from . import itunes
from .text import containment, fold, jaccard, name_tokens, title_similarity, tokens
from .youtube import VideoEvidence

SEPARATORS = re.compile(r"\s+[|•·⟡⌁]\s+|\s+[-–—]+\s+|\s*:\s+|\s*\(|\)\s*")
EPISODE_NUMBER = [
    re.compile(r"#\s?(\d{1,5})\b"),
    re.compile(r"^\s*(\d{1,5})\s*[.:]\s+"),
    re.compile(r"\b(?:episode|ep\.?)\s*(\d{1,5})\b", re.I),
]
APPLE_SHOW_LINK = re.compile(r"podcasts\.apple\.com/[^\s\"']*?/id(\d{6,12})")
CLIP_WORDS = re.compile(r"\b(clip|clips|highlights?|preview|trailer|shorts?|teaser|excerpt)\b", re.I)


@dataclass
class Candidate:
    title: str
    show: str
    collection_id: int
    guid: str | None
    audio_url: str | None
    published: str | None
    duration_s: int | None
    score: float
    reasons: list[str] = field(default_factory=list)


@dataclass
class Result:
    status: str                     # "confident" | "review" | "none"
    reason: str
    match: Candidate | None = None
    candidates: list[Candidate] = field(default_factory=list)
    show: str | None = None

    def to_json(self) -> dict:
        return asdict(self)


# ---------------------------------------------------------------- evidence

def episode_numbers(title: str) -> set[int]:
    nums = set()
    for pattern in EPISODE_NUMBER:
        for m in pattern.finditer(title):
            n = int(m.group(1))
            if 0 < n < 20000 and not (1900 <= n <= 2100):
                nums.add(n)
    return nums


def title_segments(title: str) -> list[str]:
    return [s.strip() for s in SEPARATORS.split(title) if s and s.strip()]


def content_title(title: str, show_names: list[str]) -> str:
    """The title without segments that just name the show."""
    keep = []
    for seg in title_segments(title):
        seg_tokens = set(name_tokens(re.sub(r"#?\d+", "", seg)))
        if not seg_tokens:
            continue
        # Drop the segment when it is the show's name or a part of it
        # ("Mindscape 369", "SmartLess", "Lex Fridman Podcast #502").
        if any(seg_tokens <= set(name_tokens(n)) for n in show_names if n):
            continue
        keep.append(seg)
    return " ".join(keep) or title


def _date(value: str | None) -> dt.date | None:
    if not value:
        return None
    try:
        return dt.date.fromisoformat(value[:10])
    except ValueError:
        return None


def days_apart(a: str | None, b: str | None) -> int | None:
    da, db = _date(a), _date(b)
    if not da or not db:
        return None
    return abs((da - db).days)


# ---------------------------------------------------------------- stage 1

@dataclass
class ShowCandidate:
    collection_id: int
    name: str
    artist: str
    strength: float           # 0..1, how well the name is backed by the video
    via: list[str]


def _name_support(show: dict, video: VideoEvidence) -> float:
    """How strongly the channel name or a title segment names this show."""
    names = [show.get("collectionName") or "", show.get("artistName") or ""]
    show_tokens = name_tokens(names[0])
    artist_tokens = name_tokens(names[1])
    if not show_tokens:
        return 0.0
    best = 0.0
    sources = [video.channel] + title_segments(video.title)
    for i, src in enumerate(sources):
        src_tokens = name_tokens(re.sub(r"#?\d+", "", src))
        if not src_tokens:
            continue
        # Every token of the show's name appears in the source, and the source
        # is mostly the show's name (not a long sentence that happens to
        # contain one of its words).
        for target in (show_tokens, artist_tokens):
            if not target:
                continue
            inside = len(set(target) & set(src_tokens)) / len(set(target))
            j = jaccard(target, src_tokens)
            if inside >= 0.99 and (j >= 0.5 or (i == 0 and j >= 0.34)):
                best = max(best, 1.0 if j >= 0.5 else 0.8)
            elif inside >= 0.99 and len(set(target)) >= 2:
                best = max(best, 0.6)
            elif j >= 0.6:
                best = max(best, 0.6)
    return best


def find_shows(video: VideoEvidence, limit: int = 3) -> list[ShowCandidate]:
    found: dict[int, ShowCandidate] = {}

    def consider(show: dict, via: str, bonus: float = 0.0):
        cid = show.get("collectionId")
        if not cid or show.get("kind") not in (None, "podcast"):
            return
        strength = min(1.0, _name_support(show, video) + bonus)
        if cid in found:
            found[cid].strength = max(found[cid].strength, strength)
            found[cid].via.append(via)
        else:
            found[cid] = ShowCandidate(cid, show.get("collectionName") or "",
                                       show.get("artistName") or "", strength, [via])

    # Apple links in the description name the show outright, but descriptions
    # also link guests' shows and sponsors, so they add support, not proof.
    for cid in dict.fromkeys(APPLE_SHOW_LINK.findall(video.description or ""))[:3]:
        show = itunes.lookup_show(int(cid))
        if show:
            consider(show, "description_link", bonus=0.3)

    terms = [video.channel]
    for seg in title_segments(video.title):
        seg = re.sub(r"#\s?\d+|\b\d{1,5}\b", "", seg).strip()
        if seg and re.search(r"\b(podcast|show|radio|cast|pod)\b|cast\b", seg, re.I):
            terms.append(seg)
    # Last segment of a multi-part title is often the show ("... | SmartLess").
    segs = title_segments(video.title)
    if len(segs) >= 2 and len(name_tokens(segs[-1])) <= 5:
        terms.append(re.sub(r"#\s?\d+|\b\d{1,5}\b", "", segs[-1]).strip())
    for term in dict.fromkeys(t for t in terms if t and len(fold(t)) >= 3):
        for show in itunes.search_shows(term, limit=8):
            consider(show, f"search:{term}")

    ranked = sorted(found.values(), key=lambda s: -s.strength)
    return [s for s in ranked if s.strength >= 0.6][:limit]


# ---------------------------------------------------------------- stage 2

def _duration_agreement(video_s: int | None, episode_s: int | None) -> str:
    """'match', 'close', 'mismatch' or 'unknown'."""
    if not video_s or not episode_s:
        return "unknown"
    diff = abs(video_s - episode_s)
    ratio = diff / max(video_s, episode_s)
    # Feeds add ads and intros; YouTube cuts them. Allow some drift.
    if diff <= 180 or ratio <= 0.06:
        return "match"
    if ratio <= 0.2:
        return "close"
    return "mismatch"


def score_episode(ep: dict, video: VideoEvidence, show: ShowCandidate | None,
                  show_names: list[str]) -> Candidate:
    reasons = []
    ep_title = ep.get("trackName") or ""
    yt_title = content_title(video.title, show_names)
    t_sim = max(title_similarity(yt_title, ep_title), title_similarity(video.title, ep_title))
    score = 0.45 * t_sim
    reasons.append(f"title {t_sim:.2f}")

    yt_nums, ep_nums = episode_numbers(video.title), episode_numbers(ep_title)
    if yt_nums and ep_nums:
        if yt_nums & ep_nums:
            score += 0.25
            reasons.append("episode number")
        else:
            score -= 0.25
            reasons.append("episode number differs")

    desc_sim = 0.0
    ep_desc = ep.get("description") or ep.get("shortDescription") or ""
    if video.description and ep_desc:
        a = tokens(video.description[:1200])
        b = tokens(ep_desc[:1200])
        desc_sim = containment(a, b) if min(len(set(a)), len(set(b))) >= 12 else 0.0
        score += 0.15 * desc_sim
        reasons.append(f"description {desc_sim:.2f}")

    days = days_apart(video.published, ep.get("releaseDate"))
    if days is not None:
        score += 0.1 * (1 if days <= 1 else 0.6 if days <= 3 else 0.3 if days <= 7 else 0)
        reasons.append(f"{days} days apart")

    ep_s = int(ep["trackTimeMillis"] / 1000) if ep.get("trackTimeMillis") else None
    agreement = _duration_agreement(video.duration_s, ep_s)
    score += {"match": 0.1, "close": 0.05, "unknown": 0.0, "mismatch": -0.2}[agreement]
    reasons.append(f"duration {agreement}")

    if show is not None:
        score += 0.1 * show.strength
    return Candidate(
        title=ep_title,
        show=ep.get("collectionName") or "",
        collection_id=ep.get("collectionId") or 0,
        guid=ep.get("episodeGuid"),
        audio_url=ep.get("episodeUrl"),
        published=(ep.get("releaseDate") or "")[:10] or None,
        duration_s=ep_s,
        score=round(score, 4),
        reasons=reasons,
    ), {"title": t_sim, "desc": desc_sim, "days": days, "duration": agreement,
        "number": bool(yt_nums & ep_nums)}


def _is_confident(sig: dict, show: ShowCandidate | None, video: VideoEvidence) -> tuple[bool, str]:
    if show is None or show.strength < 0.8:
        return False, "show not identified"
    if sig["duration"] == "mismatch":
        return False, "durations disagree (clip or different cut)"
    if sig["duration"] == "unknown" and not sig["number"]:
        return False, "duration unknown"
    if sig["days"] is not None and sig["days"] > 7 and not sig["number"]:
        return False, "published more than a week apart"
    strong = (sig["number"] and sig["title"] >= 0.2) \
        or sig["title"] >= 0.6 \
        or (sig["title"] >= 0.35 and sig["desc"] >= 0.5 and (sig["days"] or 99) <= 3) \
        or (sig["desc"] >= 0.7 and (sig["days"] or 99) <= 2 and sig["duration"] == "match")
    if not strong:
        return False, "no strong episode evidence"
    return True, "matched"


def match(video: VideoEvidence) -> Result:
    shows = find_shows(video)
    show_names = [video.channel] + [s.name for s in shows]
    by_id = {s.collection_id: s for s in shows}

    episodes: dict[str, dict] = {}
    for s in shows:
        for ep in itunes.show_episodes(s.collection_id):
            episodes.setdefault(ep.get("episodeGuid") or ep.get("episodeUrl") or ep.get("trackName"), ep)
    # Episodes older than the show's latest 200 only surface through search.
    term = content_title(video.title, show_names)
    for ep in itunes.search_episodes(term[:100]):
        episodes.setdefault(ep.get("episodeGuid") or ep.get("episodeUrl") or ep.get("trackName"), ep)

    scored = []
    for ep in episodes.values():
        show = by_id.get(ep.get("collectionId"))
        cand, sig = score_episode(ep, video, show, show_names)
        if sig["title"] < 0.15 and not sig["number"] and sig["desc"] < 0.5:
            continue
        scored.append((cand, sig, show))
    scored.sort(key=lambda x: -x[0].score)

    top_show = shows[0].name if shows else None
    if not scored:
        return Result("none", "no podcast episode found" if shows else "no podcast found for this channel",
                      show=top_show)

    best, sig, show = scored[0]
    runner = scored[1][0].score if len(scored) > 1 else 0.0
    ok, why = _is_confident(sig, show, video)
    if ok and best.score - runner < 0.08:
        ok, why = False, "runner-up too close"
    if ok and CLIP_WORDS.search(video.title) and sig["duration"] != "match":
        ok, why = False, "looks like a clip"
    candidates = [c for c, _, _ in scored[:5]]
    if ok:
        return Result("confident", why, match=best, candidates=candidates, show=best.show)

    # Offer candidates only when there is something worth offering: an
    # identified show, or an episode that matches strongly on its own.
    plausible = [c for c, s, sh in scored[:5]
                 if (sh is not None and sh.strength >= 0.8 and c.score >= 0.3)
                 or (s["title"] >= 0.6 and s["duration"] in ("match", "close")
                     and s["days"] is not None and s["days"] <= 3)]
    if plausible:
        return Result("review", why, candidates=plausible, show=top_show)
    return Result("none", "no podcast episode found" if shows else "no podcast found for this channel",
                  show=top_show)
