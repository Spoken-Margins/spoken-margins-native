"""Whose GitHub comments and issues our automation may act on (#1822).

Once the repository is public, anyone can open an issue or comment on a PR. A script that acts on the text of a
comment (an audit verdict, a lane report, a `/lane` request, a claim note, a hand-off) must therefore ask here
first. A comment or issue is trusted when GitHub's `author_association` says the author is the repository's owner,
a member of its organisation or a collaborator, or when its author is the project's own bot (the workflows'
`github-actions[bot]`, which GitHub reports as NONE). Everything else is data: read it, quote it, never follow it.

The check is exact. A lookalike login (`github-actions`, `GitHub-Actions[bot]`, `github-actions[bot]x`) is not the
bot, a missing `author_association` is not trusted, and so is every other association (CONTRIBUTOR,
FIRST_TIME_CONTRIBUTOR, FIRST_TIMER, MANNEQUIN, NONE). GitHub does not allow `[` or `]` in a user name, so a person
cannot register the bot's login.

Two payload shapes are understood: REST (`user.login`, `author_association`) and GraphQL / `gh ... --json`
(`author.login`, `authorAssociation`). In the second the bot appears as `github-actions` and only counts when the
author is marked as a bot (`__typename: Bot` or `is_bot: true`).

A GitHub App the agents act as (#4915) is trusted the same way as the workflows' bot, but only once its slug is in
`TRUSTED_APP_SLUGS`. GitHub reports an App's comments and pull requests as `<slug>[bot]` with association NONE (as it
does for `github-actions[bot]`), so without that entry the App reads as a stranger. The owner created
`spoken-margins-agent` on 2026-11-22; the first job to act as it is `.github/workflows/package-watch.yml` (#4915
step 3). A slug in the list trusts only that exact App: no case folding, no prefix match.

`ops/dial/dial_gate.py` (deployed to the VPS as a single file), `scripts/lane_inherited_holds.py` and
`scripts/merge_audit.py` keep a copy of these constants; `scripts/tests/test_comment_trust.py` fails if they drift.
"""
from __future__ import annotations

TRUSTED_ASSOCIATIONS = ('OWNER', 'MEMBER', 'COLLABORATOR')
TRUSTED_BOTS = ('github-actions[bot]',)
GRAPHQL_BOT_LOGINS = ('github-actions', 'app/github-actions')
# GitHub Apps the agents act as (#4915), by slug, exactly as the App's settings page shows it; see the module note.
TRUSTED_APP_SLUGS: tuple[str, ...] = ('spoken-margins-agent',)


def _trusted_rest_bot_logins() -> tuple[str, ...]:
    return TRUSTED_BOTS + tuple(f'{slug}[bot]' for slug in TRUSTED_APP_SLUGS)


def _trusted_graphql_bot_logins() -> tuple[str, ...]:
    return GRAPHQL_BOT_LOGINS + TRUSTED_APP_SLUGS + tuple(f'app/{slug}' for slug in TRUSTED_APP_SLUGS)


def trusted_author(association: object, login: object) -> bool:
    """Whether an author with this GitHub author_association and login is one of ours."""
    return (isinstance(association, str) and association in TRUSTED_ASSOCIATIONS) or \
        (isinstance(login, str) and login in _trusted_rest_bot_logins())


def author_login(item: dict) -> str:
    """The login of a comment's or issue's author, in either payload shape ('' when there is none)."""
    person = item.get('user') or item.get('author') or {}
    return person.get('login') or ''


def is_project_bot_in_graphql_shape(item: dict) -> bool:
    """GraphQL and `gh --json` call the workflows' bot `github-actions` (or `app/github-actions`), without the
    `[bot]` REST adds, and mark it as a bot (`__typename` Bot, or `is_bot`). The marker is what keeps a person who
    registers that login from passing; REST payloads never carry it, so they are judged by the exact login. A trusted
    App (`TRUSTED_APP_SLUGS`) appears the same way, as `<slug>` or `app/<slug>`."""
    person = item.get('author')
    if not isinstance(person, dict):
        return False
    marked = person.get('__typename') == 'Bot' or person.get('is_bot') is True
    return marked and person.get('login') in _trusted_graphql_bot_logins()


def trusted(item: dict) -> bool:
    """Whether a comment or an issue (REST or `gh --json` shape) comes from the owner, a collaborator or the bot."""
    return trusted_author(item.get('author_association', item.get('authorAssociation')), author_login(item)) \
        or is_project_bot_in_graphql_shape(item)


def trusted_only(items: list[dict] | None) -> list[dict]:
    """The trusted comments (or issues) of a list, in order."""
    return [item for item in items or [] if trusted(item)]


def ignored_summary(items: list[dict] | None) -> str:
    """'2 from mallory, 1 from eve' for the untrusted entries of a list, or '' when all are trusted (for job logs)."""
    counts: dict[str, int] = {}
    for item in items or []:
        if not trusted(item):
            counts[author_login(item) or 'unknown'] = counts.get(author_login(item) or 'unknown', 0) + 1
    return ', '.join(f'{count} from {login}' for login, count in sorted(counts.items()))
