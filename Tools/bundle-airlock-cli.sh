#!/bin/bash
set -euo pipefail

# Copy only version-controlled runtime inputs. Developer provisioning files
# beside the source scripts must never enter a signed app.
source_dir="$(cd "$(dirname "$0")/CLI" && pwd)"
mode=$1
destination=$2
programs=(airlock-setup bin/claude bin/airlock-cli-start helpers/ssh peer-relay ssh-connect)
resources=(README.md ssh_config.airlock)
entries=(bin helpers VERSION "${programs[@]}" "${resources[@]}")

[[ "${destination##*/}" == AirlockCLI && ! -L "$destination" ]]
if [[ -d "$destination" ]]; then
    while IFS= read -r -d '' path; do
        [[ "$path" == "$destination" ]] && continue
        name="${path#"$destination"/}"
        known=false
        for entry in "${entries[@]}"; do
            if [[ "$name" == "$entry" && ! -L "$path" ]]; then known=true; break; fi
        done
        if ! "$known"; then
            echo "Unexpected file in AirlockCLI resources; use a clean build directory." >&2
            exit 1
        fi
    done < <(/usr/bin/find "$destination" -print0)
fi

case "$mode" in
    build)
        : "${MARKETING_VERSION:?}" "${CURRENT_PROJECT_VERSION:?}"
        mkdir -p "$destination/bin" "$destination/helpers"
        for name in "${programs[@]}"; do
            /usr/bin/install -m 755 "$source_dir/$name" "$destination/$name"
        done
        for name in "${resources[@]}"; do
            /usr/bin/install -m 644 "$source_dir/$name" "$destination/$name"
        done
        printf '%s (%s)\n' "$MARKETING_VERSION" "$CURRENT_PROJECT_VERSION" > "$destination/VERSION"
        ;;
    verify|package-version) ;;
    *) echo "Usage: bash bundle-airlock-cli.sh build|verify|package-version APP_RESOURCES/AirlockCLI" >&2; exit 2 ;;
esac

for name in "${programs[@]}" "${resources[@]}"; do
    if [[ -L "$source_dir/$name" ]] || ! /usr/bin/cmp -s "$source_dir/$name" "$destination/$name"; then
        echo "Export missing the current AirlockCLI/$name; rebuild the standalone archive." >&2
        exit 1
    fi
done
for name in "${programs[@]}"; do [[ -x "$destination/$name" ]]; done
[[ -s "$destination/VERSION" ]]

if [[ "$mode" != build ]]; then
    info="$destination/../../Info.plist"
    version=$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$info")
    build=$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$info")
    if [[ "$(<"$destination/VERSION")" != "$version ($build)" ]]; then
        echo "The embedded terminal tools do not match the exported app version." >&2
        exit 1
    fi
    if [[ "$mode" == package-version ]]; then printf '%s.%s\n' "$version" "$build"; fi
fi
