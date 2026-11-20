#!/bin/bash
set -euo pipefail

tools_dir="$(cd "$(dirname "$0")" && pwd)"
root=$1
output=$2
contents="$root/Deus Airlock.app/Contents"
version=$(/bin/bash "$tools_dir/bundle-airlock-cli.sh" package-version "$contents/Resources/AirlockCLI")
identifier=$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$contents/Info.plist")
exec /usr/bin/pkgbuild --root "$root" \
    --component-plist "$tools_dir/../SFM.System/component.plist" \
    --identifier "$identifier" --version "$version" \
    --install-location /Applications --min-os-version 13.0 --compression latest "$output"
