#!/usr/bin/env python3
"""Build kiwix/landing/index.html: the Kiwix welcome page (topic tiles + search).

    python3 ~/HomeLab/kiwix/landing/build.py

Edit TILES below or template.html, then rerun. Tile images come from the Wikipedia ZIM itself
(the lead image of an article), fetched through the running kiwix container and embedded as
data: URIs, so the page has no outside dependencies and survives ZIM updates (asset paths
change between ZIM builds; embedded copies do not). kiwix/update.sh reruns this after an update.
Needs: the kiwix container running on proxy-net. Writes index.html next to this file.
"""
import base64, html, json, re, subprocess, sys, urllib.parse, urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
BOOK = "wikipedia_en_all_maxi"          # date-free alias (kiwix-serve --nodatealiases)

# (section, [(title, caption, portal or article to open, article with the image, image file substring)])
TILES = [
    ("Science & nature", [
        ("Science",     "Discovery and the scientific method", "Portal:Science",        "Physics",               "Newton's_Cradle"),
        ("Mathematics", "Numbers, shapes, proofs",             "Portal:Mathematics",    "Mathematics",           "Woman_teaching_geometry"),
        ("Space",       "Planets, stars, the universe",        "Portal:Astronomy",      "Astronomy",             "Titan_in_front_of_the_ring"),
        ("Earth",       "Geology, oceans, climate",            "Portal:Earth_sciences", "Earth",                 "Meteosat"),
        ("Biology",     "Life, cells, evolution",              "Portal:Biology",        "Biology",               "Issoria_lathonia"),
        ("Animals",     "The animal kingdom",                  "Portal:Animals",        "Portal:Animals",        "Animal_diversity_b"),
        ("Medicine",    "Health, disease, treatment",          "Portal:Medicine",       "Medicine",              "The_Doctor_Luke_Fildes"),
        ("Technology",  "Machines, energy, inventions",        "Portal:Technology",     "Technology",            "Dampfturbine_Montage01"),
    ]),
    ("Arts & humanities", [
        ("History",     "From prehistory to today",            "Portal:History",        "History",               "Carstian_Luyckx"),
        ("Geography",   "Countries, places, maps",             "Portal:Geography",      "Geography",             "Theatrum_Orbis_Terrarum"),
        ("Philosophy",  "Ideas, ethics, logic",                "Portal:Philosophy",     "Philosophy",            "Le_Penseur"),
        ("Religion",    "Faiths and traditions",               "Portal:Religion",       "Religion",              "Sakyamuni"),
        ("Literature",  "Books, poetry, writers",              "Portal:Literature",     "Literature",            "Lunon"),
        ("Visual arts", "Painting, sculpture, design",         "Portal:Visual_arts",    "Portal:Visual_arts",    "Church_in_Auvers"),
        ("Music",       "Genres, instruments, artists",        "Portal:Music",          "Music",                 "The_Sounds_of_Earth"),
        ("Film",        "Cinema and filmmakers",               "Portal:Film",           "Portal:Film",           "Man_working_with_a_projector"),
    ]),
    ("People & everyday life", [
        ("Society",      "Culture, family, communities",       "Portal:Society",               "Society",      "Lao_Mangkong"),
        ("Politics",     "Government, law, elections",         "Portal:Politics",              "Politics",     "Abertura_do_Debate"),
        ("Economics",    "Money, markets, trade",              "Portal:Economics",             "Portal:Business", "Norwich_Market"),
        ("Language",     "Words, writing, linguistics",        "Portal:Language",              "Language",     "Cuneiform_tablet_of_merchant"),
        ("Architecture", "Buildings and cities",               "Portal:Architecture",          "Architecture", "Santa_Maria_del_Fiore"),
        ("Computing",    "Computers and programming",          "Portal:Computer_programming",  "Computer",     "ENIAC-changing"),
        ("Sports",       "Games, athletes, competition",       "Portal:Sports",                "Sport",        "London_Marathon"),
        ("Food",         "Cuisine, cooking, drink",            "Portal:Food",                  "Food",         "Good_Food_Display"),
    ]),
]


def kiwix_base():
    ip = subprocess.run(["docker", "inspect", "kiwix", "--format",
                         "{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}"],
                        capture_output=True, text=True, check=True).stdout.split()[0]
    return f"http://{ip}:8080"


def fetch(url):
    with urllib.request.urlopen(url, timeout=30) as r:
        return r.read(), r.headers.get_content_type()


def main():
    base = kiwix_base()
    cat = fetch(f"{base}/catalog/v2/entries")[0].decode()
    updated = re.findall(r"<updated>(\d{4})-(\d{2})-\d{2}T", cat)
    y, m = updated[-1] if updated else ("", "")
    months = "January February March April May June July August September October November December".split()
    edition = f"{months[int(m) - 1]} {y}" if m else "current"

    sections, missing = [], []
    for name, tiles in TILES:
        cards = []
        for title, caption, target, src, needle in tiles:
            page = fetch(f"{base}/content/{BOOK}/{urllib.parse.quote(src)}")[0].decode("utf-8", "replace")
            hit = next((s for s in re.findall(r'src="(\./_assets_/[^"]+)"', page)
                        if needle in urllib.parse.unquote(urllib.parse.unquote(s)) or needle in s), None)
            img = ""
            if hit:
                data, ctype = fetch(f"{base}/content/{BOOK}/{hit[2:]}")
                img = f'<img src="data:{ctype};base64,{base64.b64encode(data).decode()}" alt="">'
            else:
                missing.append(f"{title} ({src} / {needle})")
            href = f"/viewer#{BOOK}/{urllib.parse.quote(target, safe=':/')}"
            tid = "tile-" + re.sub(r"[^a-z0-9]+", "-", title.lower()).strip("-")
            cards.append(f'    <a class="tile" id="{tid}" href="{href}">{img}'
                         f'<div class="label"><strong>{html.escape(title)}</strong>'
                         f'<span>{html.escape(caption)}</span></div></a>')
        sid = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")
        sections.append(f'  <section id="sec-{sid}" aria-labelledby="h-{sid}">\n'
                        f'    <h2 id="h-{sid}">{html.escape(name)}</h2>\n    <div class="grid">\n'
                        + "\n".join(cards) + "\n    </div>\n  </section>")

    out = (HERE / "template.html").read_text()
    out = out.replace("{{SECTIONS}}", "\n".join(sections)).replace("{{EDITION}}", edition).replace("{{BOOK}}", BOOK)
    target = HERE / "index.html"
    # write in place (same inode), so the read-only bind mount keeps seeing the file
    with open(target, "w") as f:
        f.write(out)
    print(f"wrote {target} ({len(out) // 1024} KB, edition {edition})")
    if missing:
        print("tiles without an image (check the article / needle):", *missing, sep="\n  ")
        sys.exit(2)


if __name__ == "__main__":
    main()
