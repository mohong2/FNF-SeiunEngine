#!/usr/bin/env python3
"""
Refresh the offline GitHub contributor snapshot used by the credits screen.

The game fetches contributors live when it can, but it must still show something on a
machine without network access. This tool produces that fallback:

    assets/preload/data/github_contributors.json   name / link / contributions
    assets/preload/images/credits/github/*.png     bundled 150px avatars

Usage (from the repository root):

    python tools/gen_contributors.py
    python tools/gen_contributors.py --max 30
    GITHUB_TOKEN=ghp_... python tools/gen_contributors.py

Only the standard library is used. A token is optional; unauthenticated requests are
limited to 60/hour per IP, which is plenty for a manual refresh.
"""

from __future__ import annotations

import argparse
import datetime
import json
import os
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DATA_PATH = ROOT / "assets" / "preload" / "data" / "github_contributors.json"
AVATAR_DIR = ROOT / "assets" / "preload" / "images" / "credits" / "github"
API = "https://api.github.com"


def request(url: str, token: str, accept: str = "application/vnd.github+json") -> bytes:
    headers = {
        "User-Agent": "SeiunEngine-gen-contributors",
        "Accept": accept,
        "X-GitHub-Api-Version": "2022-11-28",
    }
    if token:
        headers["Authorization"] = "Bearer " + token
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=30) as response:
        return response.read()


def fetch_contributors(owner: str, repo: str, token: str):
    url = f"{API}/repos/{owner}/{repo}/contributors?per_page=100"
    payload = json.loads(request(url, token).decode("utf-8"))
    if not isinstance(payload, list):
        raise SystemExit("GitHub did not return a contributor list: " + str(payload))

    out = []
    for item in payload:
        if not isinstance(item, dict):
            continue
        login = str(item.get("login") or "").strip()
        if not login:
            continue
        if str(item.get("type") or "").lower() == "bot":
            continue
        out.append(
            {
                "login": login,
                "name": "",
                "id": int(item.get("id") or 0),
                "avatarUrl": str(item.get("avatar_url") or ""),
                "profileUrl": str(item.get("html_url") or f"https://github.com/{login}"),
                "contributions": int(item.get("contributions") or 0),
            }
        )

    out.sort(key=lambda c: (-c["contributions"], c["login"].lower()))
    return out


def safe_name(login: str) -> str:
    return re.sub(r"[^A-Za-z0-9_-]", "_", login) or "unknown"


def download_avatars(contributors) -> int:
    AVATAR_DIR.mkdir(parents=True, exist_ok=True)
    saved = 0
    for item in contributors:
        url = item["avatarUrl"]
        if not url:
            continue
        separator = "&" if "?" in url else "?"
        url = f"{url}{separator}s=150"
        try:
            # No token here on purpose: avatars live on a separate CDN host and the
            # credential must not be forwarded to it.
            data = request(url, "", accept="image/*,*/*;q=0.8")
        except Exception as exc:  # noqa: BLE001 - one bad avatar must not abort the snapshot
            print(f"  avatar {item['login']}: {exc}", file=sys.stderr)
            continue
        # GitHub serves PNG for ?s=150; keep the extension stable for the asset manifest.
        path = AVATAR_DIR / (safe_name(item["login"]) + ".png")
        path.write_bytes(data)
        saved += 1
        print(f"  avatar {item['login']}: {len(data)} bytes")
    return saved


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--owner", default="mohong2")
    parser.add_argument("--repo", default="FNF-SeiunEngine")
    parser.add_argument("--max", type=int, default=30, help="keep at most N contributors (default 30)")
    parser.add_argument("--token", default=os.environ.get("GITHUB_TOKEN") or os.environ.get("SEIUN_GITHUB_TOKEN") or "")
    parser.add_argument("--no-avatars", action="store_true", help="only rewrite the JSON snapshot")
    args = parser.parse_args()

    print(f"Fetching contributors for {args.owner}/{args.repo} ...")
    try:
        contributors = fetch_contributors(args.owner, args.repo, args.token)
    except urllib.error.HTTPError as exc:
        print(f"GitHub answered HTTP {exc.code}: {exc.read().decode('utf-8', 'replace')[:400]}", file=sys.stderr)
        return 1
    except Exception as exc:  # noqa: BLE001 - CLI: report and exit
        print(f"Could not fetch contributors: {exc}", file=sys.stderr)
        return 1

    contributors = contributors[: max(0, args.max)]
    if not contributors:
        print("GitHub returned no contributors; refusing to wipe the offline snapshot.", file=sys.stderr)
        return 1

    if not args.no_avatars:
        print("Downloading avatars ...")
        download_avatars(contributors)

    payload = {
        "repository": f"{args.owner}/{args.repo}",
        "generatedAt": datetime.date.today().isoformat(),
        "note": "Offline snapshot used when GitHub is unreachable; refresh with tools/gen_contributors.py.",
        "contributors": contributors,
    }
    DATA_PATH.parent.mkdir(parents=True, exist_ok=True)
    DATA_PATH.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"Wrote {DATA_PATH.relative_to(ROOT)} ({len(contributors)} contributors).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
