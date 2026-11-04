#!/usr/bin/env python3
"""Re-add every show/movie from the backup's re-download lists into (fresh) Sonarr/Radarr.

Only needed when the Sonarr/Radarr configs themselves are lost. If you restored them from the
backup they already know everything; just run Wanted -> Missing -> Search All.

Plain stdlib, no dependencies. Dry run by default.

  python3 readd-media.py EXPORTS_DIR --sonarr http://localhost:8989 --radarr http://localhost:7878            # dry run
  python3 readd-media.py EXPORTS_DIR ... --apply            # add titles (monitored as before), no searching
  python3 readd-media.py EXPORTS_DIR ... --apply --search   # add + immediately search indexers for everything

API keys: env SONARR_API_KEY / RADARR_API_KEY (Settings -> General in each app).
EXPORTS_DIR is staging/exports from a restic restore (redownload-*.json + *-qualityprofiles.json + *-rootfolders.json).
"""
import argparse, json, os, sys, urllib.error, urllib.parse, urllib.request


def api(base, key, method, path, body=None):
    req = urllib.request.Request(base.rstrip("/") + "/api/v3" + path, method=method,
                                 data=json.dumps(body).encode() if body is not None else None,
                                 headers={"X-Api-Key": key, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            raw = r.read()
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"{method} {path} -> HTTP {e.code}: {e.read().decode()[:300]}") from None


def load(d, name):
    p = os.path.join(d, name)
    return json.load(open(p)) if os.path.exists(p) else []


def profile_map(old_profiles, new_profiles):
    """old profile id -> new profile id, matched by name (fresh installs have the same default names)."""
    by_name = {p["name"]: p["id"] for p in new_profiles}
    fallback = new_profiles[0]["id"]
    return {p["id"]: by_name.get(p["name"], fallback) for p in old_profiles}, fallback


def ensure_rootfolders(base, key, wanted, apply):
    have = {r["path"].rstrip("/") for r in api(base, key, "GET", "/rootfolder")}
    for path in sorted(wanted):
        if path.rstrip("/") not in have:
            print(f"  root folder {path}: missing -> {'adding' if apply else 'would add'}")
            if apply:
                api(base, key, "POST", "/rootfolder", {"path": path})


def do_sonarr(args, key):
    shows = load(args.exports, "redownload-shows.json")
    pmap, fallback = profile_map(load(args.exports, "sonarr-qualityprofiles.json"), api(args.sonarr, key, "GET", "/qualityprofile"))
    roots = {r["path"] for r in load(args.exports, "sonarr-rootfolders.json")} | {os.path.dirname(s["path"]) for s in shows}
    ensure_rootfolders(args.sonarr, key, roots, args.apply)
    have = {s["tvdbId"] for s in api(args.sonarr, key, "GET", "/series")}
    added = skipped = failed = 0
    for s in shows:
        if s["tvdbId"] in have:
            skipped += 1; continue
        try:
            found = api(args.sonarr, key, "GET", "/series/lookup?term=" + urllib.parse.quote(f"tvdb:{s['tvdbId']}"))
            if not found:
                raise RuntimeError("not found on lookup")
            new = found[0]
            mon = set(s.get("monitored_seasons") or [])
            for season in new.get("seasons", []):
                season["monitored"] = season["seasonNumber"] in mon
            new.update(qualityProfileId=pmap.get(s["qualityProfileId"], fallback), path=s["path"],
                       rootFolderPath=os.path.dirname(s["path"]), monitored=s["monitored"], seasonFolder=True,
                       seriesType=s.get("seriesType") or "standard",
                       addOptions={"searchForMissingEpisodes": args.search, "searchForCutoffUnmetEpisodes": False})
            print(f"  {'ADD ' if args.apply else 'would add'} show  {s['title']} ({s['year']}) seasons={sorted(mon)} -> {s['path']}")
            if args.apply:
                api(args.sonarr, key, "POST", "/series", new)
            added += 1
        except Exception as e:
            print(f"  FAIL show  {s['title']}: {e}"); failed += 1
    print(f"sonarr: {added} {'added' if args.apply else 'to add'}, {skipped} already present, {failed} failed")
    return failed


def do_radarr(args, key):
    movies = load(args.exports, "redownload-movies.json")
    pmap, fallback = profile_map(load(args.exports, "radarr-qualityprofiles.json"), api(args.radarr, key, "GET", "/qualityprofile"))
    roots = {r["path"] for r in load(args.exports, "radarr-rootfolders.json")} | {os.path.dirname(m["path"]) for m in movies}
    ensure_rootfolders(args.radarr, key, roots, args.apply)
    have = {m["tmdbId"] for m in api(args.radarr, key, "GET", "/movie")}
    added = skipped = failed = 0
    for m in movies:
        if m["tmdbId"] in have:
            skipped += 1; continue
        try:
            new = api(args.radarr, key, "GET", f"/movie/lookup/tmdb?tmdbId={m['tmdbId']}")
            new.update(qualityProfileId=pmap.get(m["qualityProfileId"], fallback), path=m["path"],
                       rootFolderPath=os.path.dirname(m["path"]), monitored=m["monitored"],
                       minimumAvailability=new.get("minimumAvailability") or "released",
                       addOptions={"searchForMovie": args.search})
            print(f"  {'ADD ' if args.apply else 'would add'} movie {m['title']} ({m['year']}) -> {m['path']}")
            if args.apply:
                api(args.radarr, key, "POST", "/movie", new)
            added += 1
        except Exception as e:
            print(f"  FAIL movie {m['title']}: {e}"); failed += 1
    print(f"radarr: {added} {'added' if args.apply else 'to add'}, {skipped} already present, {failed} failed")
    return failed


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("exports")
    ap.add_argument("--sonarr", help="e.g. http://localhost:8989")
    ap.add_argument("--radarr", help="e.g. http://localhost:7878")
    ap.add_argument("--apply", action="store_true", help="actually add (default: dry run)")
    ap.add_argument("--search", action="store_true", help="with --apply: search indexers right away")
    args = ap.parse_args()
    print("DRY RUN (add --apply to make changes)" if not args.apply else f"APPLY (search={args.search})")
    fails = 0
    if args.sonarr:
        fails += do_sonarr(args, os.environ["SONARR_API_KEY"])
    if args.radarr:
        fails += do_radarr(args, os.environ["RADARR_API_KEY"])
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
