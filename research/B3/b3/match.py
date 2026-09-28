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
import urllib.parse
from dataclasses import dataclass, field, asdict

from . import itunes, spotify
from .text import containment, fold, jaccard, name_tokens, title_similarity, tokens
from .youtube import VideoEvidence

SEPARATORS = re.compile(r"\s+[|•·⟡⌁]\s+|\s+[-–—]+\s+|\s*:\s+|\s*\(|\)\s*")
EPISODE_NUMBER = [
    re.compile(r"#\s?(\d{1,5})\b"),
    re.compile(r"^\s*(\d{1,5})\s*[.:]\s+"),
    re.compile(r"\b(?:episode|ep\.?)\s*(\d{1,5})\b", re.I),
]
APPLE_SHOW_LINK = re.compile(r"podcasts\.apple\.com/[^\s\"']*?/id(\d{6,12})")
# Words that mark a cut rather than an episode. Not "short": titles say "Short Kings";
# YouTube Shorts are recognized by their link and their length.
CLIP_WORDS = re.compile(r"\b(clip|clips|highlights?|preview|trailer|teaser|excerpt)\b", re.I)


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
    return " ".join(content_segments(title, show_names)) or title


def content_segments(title: str, show_names: list[str]) -> list[str]:
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
    return keep


def search_term(title: str, show_names: list[str]) -> str:
    """A title search Apple can answer: its search wants every word to match,
    so a run-on title with several segments finds nothing. Use the first
    segment that isn't the show's name."""
    for seg in content_segments(title, show_names):
        if len(tokens(seg)) >= 2:
            return seg[:100]
    return content_title(title, show_names)[:100]


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
    strength: float           # 0..1, how well the video backs this show's identity
    via: list[str]
    episodes: int = 0          # Apple's trackCount; look-alike shows are usually tiny


def _source_tokens(text: str) -> set[str]:
    return set(name_tokens(re.sub(r"#\s?\d+|\b\d{1,5}\b", "", text)))


def _name_support(show: dict, sources: list[tuple[str, str]], searched: str | None) -> float:
    """How strongly a named source (channel, title segment, linked show name)
    names this show.

    1.0  the source is the show's name or its publisher's name
    0.8  the source is part of the show's name, and the show came up when
         searching for that very source (e.g. "The Indicator" -> "The
         Indicator from Planet Money", channel "Changelog" -> "The Changelog")
    0.6  loose overlap, such as a shared distinctive word ("Andrew Huberman"
         and "Huberman Lab"); an episode of such a show must be unmistakable
    """
    best = 0.0
    for target_name in (show.get("collectionName") or "", show.get("artistName") or ""):
        target = set(name_tokens(target_name))
        if not target:
            continue
        for kind, src in sources:
            src_tokens = _source_tokens(src)
            if not src_tokens:
                continue
            j = jaccard(target, src_tokens)
            if kind == "title_tail" and target != src_tokens:
                if j >= 0.5 or target & src_tokens:
                    best = max(best, 0.6)
                continue
            if target <= src_tokens and j >= 0.5:
                best = max(best, 1.0)
            # Part of a short name, not a phrase inside a keyword-stuffed one
            # ("... Andrew Huberman, Joe Rogan, Stress, Anxiety ...").
            elif src_tokens <= target and len(target) - len(src_tokens) <= 4 and len(target) <= 6 \
                    and searched is not None and fold(searched) == fold(src) \
                    and (len(src_tokens) >= 2 or kind in ("channel", "linked")):
                best = max(best, 0.8)
            elif j >= 0.5 or (target & src_tokens and len(target) <= 8
                              and any(len(t) >= 4 for t in target & src_tokens)):
                best = max(best, 0.6)
    return best


def _domain(url: str | None) -> str | None:
    host = urllib.parse.urlsplit(url or "").hostname or ""
    parts = host.lower().split(".")
    return ".".join(parts[-2:]) if len(parts) >= 2 else None


# Hosting and platform domains say nothing about which show a link belongs to.
_SHARED_DOMAINS = {
    "megaphone.fm", "simplecast.com", "libsyn.com", "art19.com", "anchor.fm", "transistor.fm",
    "flightcast.com", "substack.com", "omnycontent.com", "audioboom.com", "podbean.com",
    "buzzsprout.com", "acast.com", "spreaker.com", "feedburner.com", "captivate.fm", "pdrl.fm",
    "podtrac.com", "soundcloud.com", "npr.org", "apple.com", "spotify.com", "youtube.com",
    "google.com", "amazon.com", "bit.ly", "linktr.ee", "patreon.com", "instagram.com",
    "twitter.com", "x.com", "tiktok.com", "facebook.com", "linkedin.com",
}


def show_sources(video: VideoEvidence) -> list[tuple[str, str]]:
    """Places in the video's metadata that may name its podcast."""
    sources = [("channel", video.channel)]
    segs = title_segments(video.title)
    for i, seg in enumerate(segs):
        has_number = bool(re.search(r"#\s?\d+|\b\d{1,5}\s*$", seg))
        podcasty = re.search(r"\b(podcast|show|radio|pod)\b|cast\b", seg, re.I)
        last_after_bar = i == len(segs) - 1 and len(segs) >= 2 and " | " in video.title \
            and len(_source_tokens(seg)) <= 6
        if (has_number or podcasty or last_after_bar) and _source_tokens(seg):
            # A bare trailing segment is as often the guest ("| Dr. Andy Galpin")
            # as the show ("| SmartLess"), so it is weaker evidence.
            kind = "title" if has_number or podcasty else "title_tail"
            sources.append((kind, re.sub(r"#\s?\d+|\b\d{1,5}\s*$", "", seg).strip()))
    return sources


def find_shows(video: VideoEvidence, limit: int = 3) -> list[ShowCandidate]:
    found: dict[int, ShowCandidate] = {}
    sources = show_sources(video)
    text = (video.description or "") + " " + " ".join(video.links)
    link_domains = {_domain(u) for u in video.links} - _SHARED_DOMAINS - {None}

    # A Spotify show link names the podcast outright: use its name as a source.
    for sid in list(dict.fromkeys(spotify.SHOW_LINK.findall(text)))[:2]:
        name = spotify.show_name(sid)
        if name:
            sources.append(("linked", name))

    def consider(show: dict, via: str, searched: str | None, bonus: float = 0.0):
        cid = show.get("collectionId")
        if not cid or show.get("kind") not in (None, "podcast"):
            return
        strength = _name_support(show, sources, searched)
        # The show's feed lives on a site the video links to (lexfridman.com, changelog.com).
        if _domain(show.get("feedUrl")) in link_domains:
            strength += 0.3
            via += "+feed_domain_linked"
        strength = min(1.0, strength + bonus)
        if cid in found:
            found[cid].strength = max(found[cid].strength, strength)
            found[cid].via.append(via)
        else:
            found[cid] = ShowCandidate(cid, show.get("collectionName") or "",
                                       show.get("artistName") or "", strength, [via],
                                       show.get("trackCount") or 0)

    # An Apple Podcasts link names a show, but descriptions also link guests'
    # shows and sponsors, so it adds support rather than proof.
    for cid in list(dict.fromkeys(APPLE_SHOW_LINK.findall(text)))[:3]:
        show = itunes.lookup_show(int(cid))
        if show:
            consider(show, "apple_link", None, bonus=0.3)

    for term in list(dict.fromkeys(src for _, src in sources if len(fold(src)) >= 3))[:4]:
        for show in itunes.search_shows(term, limit=8):
            consider(show, f"search:{term}", term)

    # Among shows the video backs, the one with the most episodes first: a
    # search for "Syntax" or "Lex Fridman" also returns tiny look-alikes with
    # the exact name, which would otherwise crowd out the real show.
    ranked = sorted(found.values(), key=lambda s: (-(s.strength >= 0.8), -s.episodes, -s.strength))
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


def _longest_common_run(a: list[str], b: list[str]) -> int:
    """Length of the longest run of words the two texts share, in order."""
    if not a or not b:
        return 0
    best, prev = 0, [0] * (len(b) + 1)
    for x in a:
        cur = [0] * (len(b) + 1)
        for j, y in enumerate(b, 1):
            if x == y:
                cur[j] = prev[j - 1] + 1
                if cur[j] > best:
                    best = cur[j]
        prev = cur
    return best


def _description_overlap(a: str, b: str, boilerplate: frozenset = frozenset()) -> float:
    """How much of the episode-specific description text the two share.

    Many shows paste the same episode notes on YouTube and in the feed, so
    this is strong evidence even when titles differ. Words that recur across
    most of a show's episodes (sponsor reads, links, sign-offs) are dropped
    first, so shared boilerplate can't make two different episodes look alike.
    The result is the larger of word-set overlap and the longest shared run of
    words (25 in a row counts as full), since one side often adds a long
    trailer the other doesn't have."""
    ta = [t for t in tokens(a[:2500]) if t not in boilerplate]
    tb = [t for t in tokens(b[:2500]) if t not in boilerplate]
    if min(len(set(ta)), len(set(tb))) < 15:
        return 0.0
    short, long_ = (ta, tb) if len(set(ta)) <= len(set(tb)) else (tb, ta)
    overlap = containment(short[:120], long_)
    run = _longest_common_run(ta[:300], tb[:300]) / 25
    return min(1.0, max(overlap, run))


def _boilerplate(episodes: list[dict]) -> dict[int, frozenset]:
    """Per show, words found in at least 40% of its episodes' descriptions."""
    by_show: dict[int, list[set]] = {}
    for ep in episodes:
        desc = ep.get("description") or ep.get("shortDescription") or ""
        by_show.setdefault(ep.get("collectionId") or 0, []).append(set(tokens(desc[:2500])))
    out = {}
    for cid, docs in by_show.items():
        if len(docs) < 5:
            out[cid] = frozenset()
            continue
        df: dict[str, int] = {}
        for d in docs:
            for t in d:
                df[t] = df.get(t, 0) + 1
        out[cid] = frozenset(t for t, n in df.items() if n >= max(3, 0.4 * len(docs)))
    return out


@dataclass
class Signals:
    title: float
    desc: float
    days: int | None
    duration: str
    number: bool | None     # True match, False conflict, None not comparable


def score_episode(ep: dict, video: VideoEvidence, show: ShowCandidate | None,
                  show_names: list[str], boilerplate: frozenset = frozenset()
                  ) -> tuple[Candidate, Signals]:
    ep_title = ep.get("trackName") or ""
    yt_title = content_title(video.title, show_names)
    t_sim = max(title_similarity(yt_title, ep_title), title_similarity(video.title, ep_title))
    yt_nums, ep_nums = episode_numbers(video.title), episode_numbers(ep_title)
    number = bool(yt_nums & ep_nums) if yt_nums and ep_nums else None
    desc = _description_overlap(video.description or "",
                                ep.get("description") or ep.get("shortDescription") or "",
                                boilerplate)
    days = days_apart(video.published, ep.get("releaseDate"))
    ep_s = int(ep["trackTimeMillis"] / 1000) if ep.get("trackTimeMillis") else None
    duration = _duration_agreement(video.duration_s, ep_s)

    score = 0.35 * t_sim + 0.25 * desc
    score += {True: 0.25, False: -0.3, None: 0.0}[number]
    if days is not None:
        score += 0.1 * (1 if days <= 1 else 0.6 if days <= 3 else 0.3 if days <= 7 else 0)
    score += {"match": 0.1, "close": 0.05, "unknown": 0.0, "mismatch": -0.2}[duration]
    if show is not None:
        score += 0.1 * show.strength

    reasons = [f"title {t_sim:.2f}", f"description {desc:.2f}",
               f"{days} days apart" if days is not None else "date unknown",
               f"duration {duration}"]
    if number is not None:
        reasons.append("episode number " + ("matches" if number else "differs"))
    cand = Candidate(
        title=ep_title,
        show=ep.get("collectionName") or "",
        collection_id=ep.get("collectionId") or 0,
        guid=ep.get("episodeGuid"),
        audio_url=ep.get("episodeUrl"),
        published=(ep.get("releaseDate") or "")[:10] or None,
        duration_s=ep_s,
        score=round(score, 4),
        reasons=reasons,
    )
    return cand, Signals(t_sim, desc, days, duration, number)


def _is_confident(sig: Signals, show: ShowCandidate | None) -> tuple[bool, str]:
    if show is None:
        return False, "episode is from a show the video doesn't name"
    if sig.number is False:
        return False, "episode numbers differ"
    if sig.duration == "mismatch":
        return False, "lengths differ (a clip or a different cut)"
    if sig.duration == "unknown" and not sig.number and sig.desc < 0.8:
        return False, "length unknown"
    near = sig.days is not None and sig.days <= 3
    week = sig.days is not None and sig.days <= 7
    if show.strength >= 0.8:
        strong = (sig.number and sig.title >= 0.2) \
            or (sig.title >= 0.6 and week) \
            or (sig.title >= 0.35 and sig.desc >= 0.4 and near) \
            or (sig.desc >= 0.6 and near) \
            or (sig.desc >= 0.8 and week)
    else:
        # Show only loosely backed: the episode itself must be unmistakable.
        strong = sig.desc >= 0.8 and near and sig.duration == "match"
    if not strong:
        return False, "no strong episode evidence"
    return True, "matched"


def _key(ep: dict) -> str:
    return ep.get("episodeGuid") or ep.get("episodeUrl") or ep.get("trackName") or ""


def _episode_show(ep: dict, video: VideoEvidence, by_id: dict, sig: "Signals",
                  lookups: dict) -> ShowCandidate | None:
    """The episode's show, if the video backs it: either one found in stage 1,
    or one an episode search surfaced whose own name or publisher the video
    names (a look-alike can crowd the real show out of stage 1). Episode
    results carry no publisher, so a promising episode's show is looked up."""
    cid = ep.get("collectionId")
    if cid in by_id:
        return by_id[cid]
    if not cid:
        return None
    show = {"collectionName": ep.get("collectionName"), "artistName": ep.get("artistName")}
    promising = sig.title >= 0.6 or sig.desc >= 0.6 or sig.number
    if not show["artistName"] and promising:
        if cid not in lookups:
            lookups[cid] = itunes.lookup_show(cid) or {}
        show["artistName"] = lookups[cid].get("artistName")
    strength = _name_support(show, show_sources(video), None)
    if strength >= 0.6:
        return ShowCandidate(cid, show["collectionName"] or "", show["artistName"] or "",
                             strength, ["episode_search"])
    return None


def _rank(episodes, video, by_id, show_names, lookups):
    scored = []
    boiler = _boilerplate(list(episodes.values()))
    for ep in episodes.values():
        bp = boiler.get(ep.get("collectionId") or 0, frozenset())
        _, sig = score_episode(ep, video, None, show_names, bp)
        if sig.title < 0.15 and not sig.number and sig.desc < 0.4:
            continue
        show = _episode_show(ep, video, by_id, sig, lookups)
        cand, sig = score_episode(ep, video, show, show_names, bp)
        scored.append((cand, sig, show))
    scored.sort(key=lambda x: -x[0].score)
    return scored


def _decide(scored, video):
    best, sig, show = scored[0]
    # Competitors are episodes of shows the video backs. An episode from an
    # unbacked show (often a copycat re-upload of the same feed) can never be
    # the confident answer, so it can't make the answer wrong either.
    rivals = [c.score for c, _, sh in scored[1:] if sh is not None]
    runner = rivals[0] if rivals else 0.0
    ok, why = _is_confident(sig, show)
    if ok and best.score - runner < 0.1:
        ok, why = False, "another episode scores almost as well"
    if ok and CLIP_WORDS.search(video.title) and sig.duration != "match":
        ok, why = False, "looks like a clip"
    return ok, why


def match(video: VideoEvidence) -> Result:
    shows = find_shows(video)
    show_names = [video.channel] + [s.name for s in shows]
    by_id = {s.collection_id: s for s in shows}

    episodes: dict[str, dict] = {}
    for s in shows:
        if s.strength < 0.8:
            continue    # loosely backed shows are only met through the episode search
        for ep in itunes.show_episodes(s.collection_id):
            episodes.setdefault(_key(ep), ep)
    lookups: dict = {}
    scored = _rank(episodes, video, by_id, show_names, lookups)
    ok, why = _decide(scored, video) if scored else (False, "")
    if not ok:
        # Older episodes (beyond the latest 200) and shows the video doesn't
        # name only surface through an episode search by title.
        for ep in itunes.search_episodes(search_term(video.title, show_names)):
            episodes.setdefault(_key(ep), ep)
        scored = _rank(episodes, video, by_id, show_names, lookups)
        ok, why = _decide(scored, video) if scored else (False, "")

    top_show = shows[0].name if shows else None
    nothing = "no matching episode in the show's feed" if shows else "no podcast found for this channel"
    if not scored:
        return Result("none", nothing, show=top_show)
    best = scored[0][0]
    candidates = [c for c, _, _ in scored[:5]]
    if ok:
        return Result("confident", why, match=best, candidates=candidates, show=best.show)

    # Offer candidates only when there is something worth offering: an
    # identified show, or an episode that matches strongly on its own.
    plausible = [c for c, sg, sh in scored[:5]
                 if (sh is not None and sh.strength >= 0.8 and c.score >= 0.35)
                 or (sg.title >= 0.6 and sg.duration in ("match", "close")
                     and sg.days is not None and sg.days <= 3)
                 or (sg.desc >= 0.6 and sg.days is not None and sg.days <= 7)
                 # Same title the same week, but a different cut: worth asking about.
                 or (sg.title >= 0.8 and sg.days is not None and sg.days <= 3)]
    if plausible:
        return Result("review", why, candidates=plausible, show=top_show)
    return Result("none", nothing, show=top_show)
