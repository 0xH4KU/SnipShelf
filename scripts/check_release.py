#!/usr/bin/env python3
"""Validate the release ZIP, including its extracted signature."""
import plistlib
import re
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

archive = Path(sys.argv[1]).resolve()
prefix = "SnipShelf.app/Contents/"
expected = {
    prefix + "Info.plist",
    prefix + "MacOS/SnipShelf",
    prefix + "Resources/AppIcon.icns",
    prefix + "Resources/LICENSE",
    prefix + "_CodeSignature/CodeResources",
}
with zipfile.ZipFile(archive) as bundle:
    files = [entry.filename for entry in bundle.infolist() if not entry.is_dir()]
    assert len(files) == len(expected) and set(files) == expected, "Unexpected archive contents"
    for name in files:
        data = bundle.read(name)
        assert not re.search(rb"/(?:Users|home|Volumes)/|/(?:private/)?var/folders/", data), f"Local path in {name}"
        assert b"PRIVATE KEY-----" not in data, f"Private key in {name}"
    info = plistlib.loads(bundle.read(prefix + "Info.plist"))
    assert info["CFBundleIdentifier"] == "org.snipshelf.app"
    assert info["CFBundleVersion"] == "4"
    assert info["CFBundleShortVersionString"] == "0.3.0"
    assert info["LSMinimumSystemVersion"] == "26.0"
    assert archive.name == f"SnipShelf-{info['CFBundleShortVersionString']}-arm64.zip"

with tempfile.TemporaryDirectory(prefix="snipshelf-release-check-") as directory:
    subprocess.run(["ditto", "-x", "-k", str(archive), directory], check=True)
    app = Path(directory) / "SnipShelf.app"
    subprocess.run(["codesign", "--verify", "--strict", str(app)], check=True)
    signature = subprocess.run(["codesign", "-dvv", str(app)], capture_output=True, text=True, check=True).stderr
    assert "Signature=adhoc" in signature and "TeamIdentifier=not set" in signature
    assert "Authority=" not in signature, "Unexpected signing certificate"
    executable = app / "Contents/MacOS/SnipShelf"
    architectures = subprocess.check_output(["lipo", "-archs", str(executable)], text=True).strip()
    assert architectures == "arm64", architectures
print("Release ZIP passed: version, contents, local-path scan, arm64, and extracted ad-hoc signature.")
