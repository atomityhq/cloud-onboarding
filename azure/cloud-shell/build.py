#!/usr/bin/env python3
"""Build the Cloud Shell script for a release.

Stamps the script version, the pinned Terraform release tag and that release
archive's SHA-256 into atomity-azure.sh, and writes the result and its checksum
to dist/. The wizard embeds dist/atomity-azure.sh.sha256 in the command it
generates, so the script is verified before it runs, and the script then
verifies the Terraform archive it downloads.

    python3 build.py --version 1.0.0                       # pins the tag in TERRAFORM_TAG
    python3 build.py --tf-tag azure-tf-v1.0.0 --version 1.0.0
    python3 build.py --tf-tag azure-tf-v1.0.0 --version 1.0.0 --zip ./azure-tf-v1.0.0.zip

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
RELEASES = "https://github.com/atomity/cloud-onboarding/releases/download"
PLACEHOLDERS = ("@@SCRIPT_VERSION@@", "@@TF_TAG@@", "@@TF_SHA256@@")


def sha256_of(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--tf-tag", help="Terraform release the script pins, e.g. azure-tf-v1.0.0. Defaults to the tag in TERRAFORM_TAG.")
    p.add_argument("--version", required=True, help="Script version, e.g. 1.0.0 (tag azure-shell-v1.0.0)")
    p.add_argument("--zip", help="Local copy of the Terraform release archive. Downloaded when omitted.")
    p.add_argument("--out", default=str(HERE / "dist"), help="Output directory (default: dist/)")
    a = p.parse_args()

    if not a.tf_tag:
        pin = HERE / "TERRAFORM_TAG"
        if not pin.is_file():
            sys.exit("Pass --tf-tag, or create TERRAFORM_TAG with the Terraform release tag to pin.")
        a.tf_tag = pin.read_text().strip()
    if not re.fullmatch(r"azure-tf-v\d+\.\d+\.\d+", a.tf_tag):
        sys.exit(f"--tf-tag must look like azure-tf-vX.Y.Z, got {a.tf_tag!r}")
    if not re.fullmatch(r"\d+\.\d+\.\d+", a.version):
        sys.exit(f"--version must look like X.Y.Z, got {a.version!r}")

    src = SOURCE.read_text()
    missing = [ph for ph in PLACEHOLDERS if ph not in src]
    if missing:
        sys.exit(f"{SOURCE.name} is missing placeholders: {', '.join(missing)}")

    if a.zip:
        data = Path(a.zip).read_bytes()
    else:
        url = f"{RELEASES}/{a.tf_tag}/{a.tf_tag}.zip"
        print(f"Downloading {url}")
        with urllib.request.urlopen(url) as r:  # raises if the release does not exist
            data = r.read()
    tf_sha = sha256_of(data)

    out = (src.replace("@@SCRIPT_VERSION@@", a.version)
              .replace("@@TF_TAG@@", a.tf_tag)
              .replace("@@TF_SHA256@@", tf_sha))
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
    print(f"Terraform pin  : {a.tf_tag}")
    print(f"Terraform SHA  : {tf_sha}")
    print(f"Script SHA     : {script_sha}")
    print(f"Wrote {target} and {target}.sha256")
    return 0


if __name__ == "__main__":
    sys.exit(main())