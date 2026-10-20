"""
Machine-translates BeamJoy's locale files with Azure Translator (free F0 tier : 2M characters a month).

en-US.json is the source. For every other language file it translates :
  - keys the file doesn't have yet,
  - keys whose English text changed since they were last translated (tracked in translate_state.json,
    next to this script : commit it with the locales).
A translation that exists and whose English didn't change is never touched, so hand fixes stay.
Each file is rewritten in en-US's order and layout ; keys en-US no longer has are dropped.

Placeholders ({name}, <map>), slash commands, file paths, HTML entities, line breaks and the names in
KEEP are sent as "don't translate" and checked to come back intact ; a string that loses one stays
English and is retried on the next run.

Setup : an Azure "Translator" resource on the F0 (free) pricing tier, then set
    AZURE_TRANSLATOR_KEY     (Keys and Endpoint : KEY 1)
    AZURE_TRANSLATOR_REGION  (Keys and Endpoint : Location/Region, e.g. westeurope)

Usage :
    python Tools/translate.py --dry-run          what would be sent, and how many characters
    python Tools/translate.py                    translate everything that's due
    python Tools/translate.py --only de_DE,fr_FR   just these languages
    python Tools/translate.py --group server     just the client or the server files
    python Tools/translate.py --check            check every file against en-US, send nothing
Progress is saved after every request : if it stops (quota, network), run it again to carry on.
"""
import argparse, hashlib, html, json, os, re, sys, time, urllib.error, urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
STATE_PATH = HERE / "translate_state.json"

# this working copy's layout, then the GitHub repo's
GROUPS = {
    "client": [ROOT / "Client/BJ/beamjoy_locales", ROOT / "BeamJoyClient/beamjoy_locales"],
    "server": [ROOT / "Server/BeamJoyServer/locales", ROOT / "BeamJoyServer/locales"],
}

# locale file -> Azure language code
LANGS = {
    "de_DE": "de", "es_419": "es-MX", "es_ES": "es", "fr_FR": "fr", "ja_JP": "ja", "ko_KR": "ko",
    "pl_PL": "pl", "pt_BR": "pt", "pt_PT": "pt-PT", "ru_RU": "ru", "zh_Hans": "zh-Hans", "zh_Hant": "zh-Hant",
}

# names never translated (whole words, case-sensitive)
KEEP = ["BeamJoy Free", "BeamJoy", "BeamMP", "BeamNG.drive", "BeamNG", "BJI", "Discord"]

ENDPOINT = "https://api.cognitive.microsofttranslator.com/translate?api-version=3.0&from=en&textType=html&to="
BATCH_ITEMS, BATCH_CHARS = 100, 9000

PROTECT = re.compile("|".join([
    r"\{[^{}\s]*\}",                                      # {name} {1}
    r"<[A-Za-z_][\w ]*>",                                 # <player_name> <map>
    r"&[a-zA-Z]+;|&#\d+;",                                # &lt; written out for the reader
    r"https?://\S+",                                      # links
    r"(?<![^\s(])/[a-z]{2,}\b(?!/)",                      # /bjupdate /login
    r"[\w.<>-]*(?:/[\w.<>*-]+){2,}/?|[\w.<>-]+/[\w.<>-]+\.[a-z]{2,4}\b|[\w.-]+/(?=\s|$)",  # paths
] + [r"(?<!\w)" + re.escape(t) + r"(?!\w)" for t in KEEP]))
LINE = re.compile(r'^(\s*)"((?:[^"\\]|\\.)*)"\s*:\s*"((?:[^"\\]|\\.)*)"(\s*,?)\s*$')
SPAN = re.compile(r'<span[^>]*\bid="p(\d+)"[^>]*>.*?</span>', re.S)


def fingerprint(text):
    return hashlib.sha1(text.encode("utf-8")).hexdigest()[:12]


def load(path):
    """a locale file as an ordered dict ; `//` comment lines allowed"""
    if not path.exists():
        return {}
    text = path.read_text(encoding="utf-8-sig")
    return json.loads("\n".join(l for l in text.splitlines() if not l.strip().startswith("//")))


def write(path, en_path, values):
    """`values` in en-US's layout (its comments, blank lines and order). A key not translated yet is
    left out, not filled with English : the game falls back to en-US for it, and the next run sees it
    as due"""
    out, last = [], None
    for line in en_path.read_text(encoding="utf-8-sig").splitlines():
        m = LINE.match(line)
        if not m:
            out.append(line)
            continue
        key = json.loads('"' + m.group(2) + '"')
        if key in values:
            last = len(out)
            out.append('%s%s: %s,' % (m.group(1), json.dumps(key, ensure_ascii=False),
                                      json.dumps(values[key], ensure_ascii=False)))
    if last is not None:
        out[last] = out[last][:-1]
    tmp = path.with_suffix(".tmp")
    tmp.write_text("\n".join(out) + "\n", encoding="utf-8", newline="\n")
    os.replace(tmp, path)


PLACEHOLDER = re.compile(r"\{[^{}\s]*\}")


def tokens_of(text):
    """what the code fills in : must match en-US in every language"""
    return sorted(PLACEHOLDER.findall(text)) + ["\n"] * text.count("\n")


def needs_translation(text):
    return re.search(r"[A-Za-z]", PROTECT.sub("", text)) is not None


def prepare(text):
    """-> (html sent to Azure, protected tokens)"""
    parts, tokens, last = [], [], 0
    for m in PROTECT.finditer(text):
        parts.append(html.escape(text[last:m.start()], quote=False))
        parts.append('<span class="notranslate" id="p%d">%s</span>' % (len(tokens), html.escape(m.group(0), quote=False)))
        tokens.append(m.group(0))
        last = m.end()
    parts.append(html.escape(text[last:], quote=False))
    return "".join(parts).replace("\n", "<br>"), tokens


def restore(translated, tokens, source):
    """the translated text, or None if a protected token got lost"""
    seen = []

    def put(m):
        seen.append(int(m.group(1)))
        return "\x00%s\x00" % m.group(1)
    text = SPAN.sub(put, translated)
    if sorted(seen) != list(range(len(tokens))):
        return None
    text = re.sub(r"\s*<br\s*/?>\s*", "\n", text)
    if re.search(r"<[^>]+>", text):
        return None
    text = html.unescape(text)
    text = re.sub("\x00(\\d+)\x00", lambda m: tokens[int(m.group(1))], text)
    if text.count("\n") != source.count("\n"):
        return None
    # each line keeps the English's spacing at its ends (Azure trims it)
    lines = []
    for mine, theirs in zip(text.split("\n"), source.split("\n")):
        lead = theirs[:len(theirs) - len(theirs.lstrip())]
        trail = theirs[len(theirs.rstrip()):]
        lines.append(lead + mine.strip() + trail)
    return "\n".join(lines)


def call_azure(code, texts):
    key = os.environ.get("AZURE_TRANSLATOR_KEY")
    region = os.environ.get("AZURE_TRANSLATOR_REGION")
    if not key or not region:
        sys.exit("Set AZURE_TRANSLATOR_KEY and AZURE_TRANSLATOR_REGION first (see the top of this file).")
    body = json.dumps([{"Text": t} for t in texts]).encode("utf-8")
    for attempt in range(8):
        req = urllib.request.Request(ENDPOINT + code, data=body, method="POST", headers={
            "Ocp-Apim-Subscription-Key": key, "Ocp-Apim-Subscription-Region": region,
            "Content-Type": "application/json; charset=UTF-8"})
        try:
            with urllib.request.urlopen(req, timeout=60) as res:
                return [r["translations"][0]["text"] for r in json.loads(res.read().decode("utf-8"))]
        except urllib.error.HTTPError as e:
            detail = e.read().decode("utf-8", "replace")
            if e.code == 429 or e.code >= 500:
                wait = int(e.headers.get("Retry-After") or 0) or min(60, 5 * 2 ** attempt)
                print("    Azure busy (%d), waiting %ds..." % (e.code, wait))
                time.sleep(wait)
                continue
            if e.code == 403:
                sys.exit("Azure refused (403) : this month's free quota is probably used up. Progress is saved ; "
                         "run again next month.\n" + detail)
            sys.exit("Azure error %d : %s" % (e.code, detail))
        except urllib.error.URLError as e:
            print("    network error (%s), retrying..." % e.reason)
            time.sleep(min(60, 5 * 2 ** attempt))
    sys.exit("Azure kept failing ; progress is saved, run again later.")


def batches(items):
    batch, size = [], 0
    for item in items:
        if batch and (len(batch) >= BATCH_ITEMS or size + len(item[1]) > BATCH_CHARS):
            yield batch
            batch, size = [], 0
        batch.append(item)
        size += len(item[1])
    if batch:
        yield batch


def group_dir(group):
    for d in GROUPS[group]:
        if (d / "en-US.json").exists():
            return d
    return None


def check(groups):
    problems = 0
    for group in groups:
        d = group_dir(group)
        en = load(d / "en-US.json")
        for stem in LANGS:
            path = d / (stem + ".json")
            if not path.exists():
                continue
            values = load(path)
            missing = [k for k in en if k not in values]
            extra = [k for k in values if k not in en]
            broken = [k for k in en if k in values and tokens_of(values[k]) != tokens_of(en[k])]
            english = [k for k in en if k in values and values[k] == en[k] and needs_translation(en[k])]
            print("%-6s %-8s missing %4d  extra %3d  placeholders differ %3d  still English %4d" % (
                group, stem, len(missing), len(extra), len(broken), len(english)))
            for k in broken[:5]:
                print("         placeholders differ : %s" % k)
            problems += len(missing) + len(extra) + len(broken)
    return problems


def main():
    ap = argparse.ArgumentParser(description=__doc__.strip().splitlines()[0])
    ap.add_argument("--dry-run", action="store_true", help="list what's due and its size, send nothing")
    ap.add_argument("--check", action="store_true", help="compare every file with en-US, send nothing")
    ap.add_argument("--only", help="comma-separated locale files, e.g. de_DE,es_419")
    ap.add_argument("--group", choices=sorted(GROUPS), help="just the client or the server files")
    args = ap.parse_args()

    groups = [args.group] if args.group else [g for g in GROUPS if group_dir(g)]
    if args.check:
        sys.exit(1 if check(groups) else 0)
    stems = args.only.split(",") if args.only else list(LANGS)
    for s in stems:
        if s not in LANGS:
            sys.exit("Unknown locale %s (known : %s)" % (s, ", ".join(LANGS)))

    state = json.loads(STATE_PATH.read_text(encoding="utf-8")) if STATE_PATH.exists() else {}
    total_chars, failed = 0, 0
    for group in groups:
        d = group_dir(group)
        en_path = d / "en-US.json"
        en = load(en_path)
        for stem in stems:
            path = d / (stem + ".json")
            if group == "server" and not path.exists():
                continue  # the server ships fewer languages
            values = load(path)
            seen = state.setdefault(group, {}).setdefault(stem, {})
            due = []
            for key, text in en.items():
                fp = fingerprint(text)
                if key in values and seen.get(key, fp) == fp:
                    seen[key] = fp  # translated, English unchanged
                elif not needs_translation(text):
                    values[key], seen[key] = text, fp  # nothing to translate ("{1} / {2}", "")
                else:
                    due.append((key, prepare(text)[0]))
            # counted with the don't-translate markup, in case Azure bills it
            chars = sum(len(h) for _, h in due)
            total_chars += chars
            print("%-6s %-8s -> %-7s %4d strings, %7d characters" % (group, stem, LANGS[stem], len(due), chars))
            if args.dry_run or not due:
                if not args.dry_run:
                    write(path, en_path, values)
                continue
            done = 0
            for batch in batches(due):
                results = call_azure(LANGS[stem], [h for _, h in batch])
                for (key, _), translated in zip(batch, results):
                    text = restore(translated, prepare(en[key])[1], en[key])
                    if text is None:
                        failed += 1
                        print("    kept English (a placeholder got lost) : %s" % key)
                        continue
                    values[key], seen[key] = text, fingerprint(en[key])
                done += len(batch)
                write(path, en_path, values)
                STATE_PATH.write_text(json.dumps(state, ensure_ascii=False, indent=1, sort_keys=True), encoding="utf-8")
                print("    %d / %d" % (done, len(due)))
            write(path, en_path, values)
    if not args.dry_run:
        STATE_PATH.write_text(json.dumps(state, ensure_ascii=False, indent=1, sort_keys=True), encoding="utf-8")
    print("%s %d characters%s" % ("Would send" if args.dry_run else "Sent", total_chars,
                                   "" if args.dry_run else ", %d kept English (retried next run)" % failed))
    if not args.dry_run:
        check(groups)


if __name__ == "__main__":
    main()
