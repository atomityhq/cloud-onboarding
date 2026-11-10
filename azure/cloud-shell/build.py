#!/usr/bin/env python3
"""Build the Cloud Shell script for a release.

Stamps the script version and the pinned Terraform releases into atomity-azure.sh, and
writes the result and its checksum to dist/. For every pinned release the script carries
that release archive's SHA-256, so it can verify what it downloads. The script runs the
newest pinned release by default, and any of them with --module-tag.

The pins are the lines of TERRAFORM_TAGS (one tag per line, blank lines and # comments
ignored), or --tf-tags.

    python3 build.py --version 1.0.0                                  # pins everything in TERRAFORM_TAGS
    python3 build.py --version 1.0.0 --tf-tags azure-tf-v1.0.0,azure-tf-v1.1.0
    python3 build.py --version 1.0.0 --zip azure-tf-v1.0.0=./a.zip    # use a local archive, repeatable

The wizard embeds dist/atomity-azure.sh.sha256 in the command it generates, so the script
is verified before it runs, and the script then verifies the Terraform archive it downloads.

Standard library only.
"""
import argparse
import hashlib
import re
import sys
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
SOURCE = HERE / "atomity-azure.sh"
PIN_FILE = HERE / "TERRAFORM_TAGS"
RELEASES = "https://github.com/atomityhq/cloud-onboarding/releases/download"
PLACEHOLDERS = ("@@SCRIPT_VERSION@@", "@@PINNED_MODULES@@")
TAG_RE = re.compile(r"azure-tf-v(\d+)\.(\d+)\.(\d+)")


def sha256_of(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def version_key(tag: str):
    return tuple(int(x) for x in TAG_RE.fullmatch(tag).groups())


def read_pin_file() -> list:
    if not PIN_FILE.is_file():
        sys.exit("Pass --tf-tags, or create TERRAFORM_TAGS with one Terraform release tag per line.")
    lines = [l.strip() for l in PIN_FILE.read_text().splitlines()]
    return [l for l in lines if l and not l.startswith("#")]


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--version", required=True, help="Script version, e.g. 1.0.0 (tag azure-shell-v1.0.0)")
    p.add_argument("--tf-tags", help="Comma-separated Terraform release tags to pin. Defaults to the lines of TERRAFORM_TAGS.")
    p.add_argument("--zip", action="append", default=[], metavar="TAG=PATH",
                   help="Local copy of a release archive, so it is not downloaded. Repeatable.")
    p.add_argument("--out", default=str(HERE / "dist"), help="Output directory (default: dist/)")
    a = p.parse_args()

    if not re.fullmatch(r"\d+\.\d+\.\d+", a.version):
        sys.exit(f"--version must look like X.Y.Z, got {a.version!r}")

    tags = [t.strip() for t in a.tf_tags.split(",") if t.strip()] if a.tf_tags else read_pin_file()
    if not tags:
        sys.exit("No Terraform releases to pin. Add at least one tag to TERRAFORM_TAGS.")
    for t in tags:
        if not TAG_RE.fullmatch(t):
            sys.exit(f"Terraform tags must look like azure-tf-vX.Y.Z, got {t!r}")
    dupes = sorted({t for t in tags if tags.count(t) > 1})
    if dupes:
        sys.exit(f"Duplicate Terraform tags: {', '.join(dupes)}")

    local = {}
    for spec in a.zip:
        tag, sep, path = spec.partition("=")
        if not sep or tag not in tags:
            sys.exit(f"--zip must be TAG=PATH for one of the pinned tags, got {spec!r}")
        local[tag] = Path(path)

    src = SOURCE.read_text()
    missing = [ph for ph in PLACEHOLDERS if ph not in src]
    if missing:
        sys.exit(f"{SOURCE.name} is missing placeholders: {', '.join(missing)}")

    pins = []
    for tag in sorted(tags, key=version_key, reverse=True):      # newest first
        if tag in local:
            data = local[tag].read_bytes()
        else:
            url = f"{RELEASES}/{tag}/{tag}.zip"
            print(f"Downloading {url}")
            with urllib.request.urlopen(url) as r:               # raises if the release does not exist
                data = r.read()
        pins.append((tag, sha256_of(data)))

    out = (src.replace("@@SCRIPT_VERSION@@", a.version)
              .replace("@@PINNED_MODULES@@", "\n".join(f"{t} {s}" for t, s in pins)))
    leftover = [ph for ph in PLACEHOLDERS if ph in out]
    if leftover:
        sys.exit(f"Placeholders left after stamping: {', '.join(leftover)}")

    dist = Path(a.out)
    dist.mkdir(parents=True, exist_ok=True)
    target = dist / "atomity-azure.sh"
    target.write_text(out)
    target.chmod(0o755)
    script_sha = sha256_of(out.encode())
    (dist / "atomity-azure.sh.sha256").write_text(f"{script_sha}  atomity-azure.sh\n")

    print(f"Script version : {a.version}")
    for i, (t, s) in enumerate(pins):
        print(f"Terraform pin  : {t}  {s}{'  (default)' if i == 0 else ''}")
    print(f"Script SHA     : {script_sha}")
    print(f"Wrote {target} and {target}.sha256")
    return 0


if __name__ == "__main__":
    sys.exit(main())