"""Generate the embedded launchd plist from this build's bundle/App Group IDs."""
import argparse
from pathlib import Path
import plistlib
import re


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", required=True)
    parser.add_argument("--app-group", required=True)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", args.base):
        parser.error("Invalid base bundle identifier")
    suffix = "." + args.base
    if not args.app_group.endswith(suffix) or not re.fullmatch(r"[A-Z0-9]{10}", args.app_group[:-len(suffix)]):
        parser.error("App Group must use the same bundle base and a valid Team ID prefix")
    label = args.base + ".helper"
    if args.output.name != label + ".plist":
        parser.error("Output filename must match the launchd label")
    payload = {
        "Label": label,
        "BundleProgram": "Contents/Helpers/RootHelper",
        "MachServices": {args.app_group + ".helper": True},
        "AssociatedBundleIdentifiers": [args.base + ".standalone"],
        "RunAtLoad": True,
        "KeepAlive": {"SuccessfulExit": False},
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(plistlib.dumps(payload))


if __name__ == "__main__":
    main()
