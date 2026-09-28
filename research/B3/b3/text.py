"""Text normalisation and similarity shared by the matcher."""
from __future__ import annotations

import re
import unicodedata

STOP = {
    "a", "an", "the", "and", "or", "of", "to", "in", "on", "for", "with", "at", "by",
    "is", "are", "it", "its", "you", "your", "i", "we", "our", "my", "me", "this", "that",
    "from", "as", "be", "how", "what", "why", "who", "when", "vs", "w", "ft", "feat",
}
# Words that describe the format rather than the content.
FORMAT = {
    "podcast", "pod", "episode", "ep", "full", "audio", "video", "official", "show",
    "live", "interview", "conversation", "clip", "clips", "highlights", "part",
}


def fold(text: str) -> str:
    text = unicodedata.normalize("NFKD", text)
    text = "".join(c for c in text if not unicodedata.combining(c))
    text = text.replace("&", " and ").replace("’", "'")
    text = re.sub(r"'s\b", "", text.lower())
    text = text.replace("'", "")
    return re.sub(r"[^a-z0-9]+", " ", text).strip()


def tokens(text: str, *, drop_format: bool = True) -> list[str]:
    out = []
    for t in fold(text).split():
        if t in STOP or (drop_format and t in FORMAT):
            continue
        out.append(t)
    return out


def jaccard(a, b) -> float:
    a, b = set(a), set(b)
    if not a or not b:
        return 0.0
    return len(a & b) / len(a | b)


def containment(a, b) -> float:
    """Share of the smaller token set found in the larger one."""
    a, b = set(a), set(b)
    if not a or not b:
        return 0.0
    return len(a & b) / min(len(a), len(b))


def title_similarity(a: str, b: str) -> float:
    """Blend of Jaccard and containment, so a feed title that adds or drops a
    show suffix or guest affiliation still scores high, but two titles that
    share one word do not."""
    ta, tb = tokens(a), tokens(b)
    if not ta or not tb:
        return 0.0
    j, c = jaccard(ta, tb), containment(ta, tb)
    small = min(len(set(ta)), len(set(tb)))
    # Containment of a one- or two-word title proves little.
    weight = 0.5 if small >= 4 else 0.3 if small >= 2 else 0.1
    return (1 - weight) * j + weight * c


def name_tokens(name: str) -> list[str]:
    """Tokens that identify a show or channel name."""
    return tokens(name) or tokens(name, drop_format=False)
