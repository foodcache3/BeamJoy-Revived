"""Bumps the build numbers, in the one place that can't be forgotten.

Three numbers have to move together whenever a change is deployed (see CLAUDE.md's Versioning
section) : the server's buildversion, the client's buildversion, and the UI_BUILD constant baked
into the version-check window, which the Angular UI compares against GE-Lua's real value to spot a
stale CEF cache. A bump that misses UI_BUILD makes every player look permanently out of date.

    python Tools/bump.py                 what the numbers are now, and what a bump would set
    python Tools/bump.py --apply         both sides + 1, the CHANGELOG header, and BJ.zip
    python Tools/bump.py --apply --server    the server's alone (a server-only change)
    python Tools/bump.py --apply --client    the client's alone, UI_BUILD with it

The `version` files (plain semver) are a separate thing : they only move at a real release, by
hand. This never touches them.
"""
import argparse
import io
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

SERVER_BUILD = "Server/BeamJoyServer/buildversion"
CLIENT_BUILD = "Client/BJ/lua/ge/extensions/beamjoy/buildversion"
UI_BUILD = "Client/BJ/ui/modModules/beamjoy/windows/versionCheck/app.js"
CHANGELOG = "CHANGELOG.md"
# the two client files a bump touches, as BJ.zip holds them (paths relative to Client/BJ)
ZIPPED = ["lua/ge/extensions/beamjoy/buildversion",
          "ui/modModules/beamjoy/windows/versionCheck/app.js"]

UI_BUILD_RE = re.compile(r"(const UI_BUILD = )(\d+)(;)")
HEADER_RE = re.compile(r"(Server build )(\d+)(, client build )(\d+)")


def path(rel):
    return os.path.join(ROOT, rel.replace("/", os.sep))


def read(rel):
    with io.open(path(rel), encoding="utf-8", newline="") as f:
        return f.read()


def write(rel, text):
    with io.open(path(rel), "w", encoding="utf-8", newline="") as f:
        f.write(text)


def build(rel):
    return int(read(rel).strip())


def repack():
    """BJ.zip is THE deployed package : a bump that isn't in it never reaches the game."""
    client = os.path.join(ROOT, "Client", "BJ")
    try:
        out = subprocess.run(["7z", "u", "../BJ.zip"] + ZIPPED, cwd=client,
                             capture_output=True, text=True)
    except OSError as err:
        print("! BJ.zip not repacked (%s) : run `7z u ../BJ.zip %s` from Client/BJ yourself"
              % (err, " ".join(ZIPPED)))
        return False
    if out.returncode != 0:
        print("! BJ.zip not repacked :\n" + (out.stderr or out.stdout))
        return False
    print("  BJ.zip   the two client files added again")
    return True


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--apply", action="store_true", help="write the bump (otherwise it's shown)")
    ap.add_argument("--server", action="store_true", help="the server's build alone")
    ap.add_argument("--client", action="store_true", help="the client's build alone, UI_BUILD with it")
    args = ap.parse_args()
    # neither side named : both, which is the safe default (they're independent integers, and a
    # change that touches both and bumps one reads as "up to date" on the other side)
    server = args.server or not args.client
    client = args.client or not args.server

    srv, cli, ui = build(SERVER_BUILD), build(CLIENT_BUILD), int(UI_BUILD_RE.search(read(UI_BUILD)).group(2))
    if ui != cli:
        print("! UI_BUILD is %d and the client's build is %d : they must match" % (ui, cli))
    nsrv, ncli = srv + (1 if server else 0), cli + (1 if client else 0)
    print("server   %d -> %d" % (srv, nsrv))
    print("client   %d -> %d  (UI_BUILD with it)" % (cli, ncli))
    if not args.apply:
        print("\nnothing written : --apply does it")
        return 0

    if server:
        write(SERVER_BUILD, str(nsrv))
    if client:
        write(CLIENT_BUILD, str(ncli))
        text, n = UI_BUILD_RE.subn(lambda m: m.group(1) + str(ncli) + m.group(3), read(UI_BUILD))
        if n != 1:
            print("! UI_BUILD not found in %s : set it to %d by hand" % (UI_BUILD, ncli))
        else:
            write(UI_BUILD, text)

    # the Unreleased section's own "Server build N, client build M" line
    text, n = HEADER_RE.subn(
        lambda m: m.group(1) + str(nsrv) + m.group(3) + str(ncli), read(CHANGELOG), count=1)
    if n != 1:
        print("! the CHANGELOG's build line wasn't found : update it by hand")
    else:
        write(CHANGELOG, text)
        print("  CHANGELOG  its Unreleased header")

    if client:
        repack()
    print("\nbumped. The changed files still have to be copied into the repo and committed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
