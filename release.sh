#!/usr/bin/env bash
set -euo pipefail

REPO="NelDaSi/altstore"
MIN_OS_VERSION="17.0"
SOURCE_BASE_URL="https://neldasi.github.io/altstore"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPS_JSON="$SCRIPT_DIR/apps.json"
APPS_META_JSON="$SCRIPT_DIR/apps-meta.json"

usage() {
  cat >&2 <<EOF
Usage: $0 [--dry-run] <ipa path> <release notes> [--slug <slug>] [--name "<App Name>"] [--subtitle "<text>"] [--icon <path-or-url>] [--tint "#RRGGBB"]

--slug, --name, --subtitle, --icon, --tint are only required when the app
(identified by its bundle ID inside the IPA) is not yet in apps.json:
  --slug and --name are then required.
For an app that already exists, the app is found automatically by bundle ID
and none of those flags are needed (--icon may still be passed to update
the app's icon).
EOF
  exit 1
}

DRY_RUN=0
SLUG=""
NAME=""
SUBTITLE=""
ICON=""
TINT=""
POSITIONAL=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --slug) SLUG="${2:-}"; shift 2 ;;
    --name) NAME="${2:-}"; shift 2 ;;
    --subtitle) SUBTITLE="${2:-}"; shift 2 ;;
    --icon) ICON="${2:-}"; shift 2 ;;
    --tint) TINT="${2:-}"; shift 2 ;;
    --) shift; while [[ $# -gt 0 ]]; do POSITIONAL+=("$1"); shift; done ;;
    -*) echo "Error: unknown flag: $1" >&2; usage ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done

[[ ${#POSITIONAL[@]} -eq 2 ]] || usage
IPA_INPUT_PATH="${POSITIONAL[0]}"
NOTES="${POSITIONAL[1]}"

# --- Step 1: prerequisites ---------------------------------------------

missing=()
for cmd in git python3 plutil shasum unzip; do
  command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
done
if [[ ${#missing[@]} -gt 0 ]]; then
  echo "Error: missing required tool(s): ${missing[*]}" >&2
  exit 1
fi

# gh is only needed for a real release, not for --dry-run.
if [[ "$DRY_RUN" -eq 0 ]]; then
  if ! command -v gh >/dev/null 2>&1; then
    cat >&2 <<'EOF'
Error: GitHub CLI (gh) is not installed.

Fix:
  brew install gh
  gh auth login

Then re-run this script.
EOF
    exit 1
  fi
  if ! gh auth status >/dev/null 2>&1; then
    cat >&2 <<'EOF'
Error: gh is installed but not authenticated.

Fix:
  gh auth login

Then re-run this script.
EOF
    exit 1
  fi
fi

if [[ ! -f "$IPA_INPUT_PATH" ]]; then
  echo "Error: IPA not found at: $IPA_INPUT_PATH" >&2
  exit 1
fi
IPA_PATH="$(cd "$(dirname "$IPA_INPUT_PATH")" && pwd)/$(basename "$IPA_INPUT_PATH")"

WORKDIR="$(mktemp -d)"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

# --- Step 2: read version/build/bundle id from the IPA -----------------

EXTRACT_DIR="$WORKDIR/extracted"
mkdir -p "$EXTRACT_DIR"
unzip -q "$IPA_PATH" -d "$EXTRACT_DIR"

APP_DIR="$(find "$EXTRACT_DIR/Payload" -maxdepth 1 -iname '*.app' | head -n1)"
if [[ -z "$APP_DIR" ]]; then
  echo "Error: could not find a .app bundle inside $IPA_PATH (Payload/*.app)" >&2
  exit 1
fi

INFO_PLIST="$APP_DIR/Info.plist"
if [[ ! -f "$INFO_PLIST" ]]; then
  echo "Error: Info.plist not found at $INFO_PLIST" >&2
  exit 1
fi

VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$INFO_PLIST")"
BUILD="$(plutil -extract CFBundleVersion raw -o - "$INFO_PLIST")"
BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw -o - "$INFO_PLIST")"

# --- Step 3: look up (or create) the app entry --------------------------

LOOKUP_HELPER="$WORKDIR/lookup_app.py"
cat > "$LOOKUP_HELPER" <<'PYEOF'
import json, sys
apps_json_path, meta_json_path, bundle_id = sys.argv[1:4]
with open(apps_json_path) as f:
    data = json.load(f)
with open(meta_json_path) as f:
    meta = json.load(f)

app = next((a for a in data["apps"] if a.get("bundleIdentifier") == bundle_id), None)
if app is None:
    print("new")
    sys.exit(0)

slug = meta.get(bundle_id, {}).get("slug")
if not slug:
    print("error: app exists in apps.json but has no slug in apps-meta.json", file=sys.stderr)
    sys.exit(1)

print("existing")
print(slug)
print(app.get("name", ""))
PYEOF

LOOKUP_OUTPUT="$(python3 "$LOOKUP_HELPER" "$APPS_JSON" "$APPS_META_JSON" "$BUNDLE_ID")"
LOOKUP_STATUS="$(echo "$LOOKUP_OUTPUT" | sed -n '1p')"

IS_NEW_APP=0
if [[ "$LOOKUP_STATUS" == "new" ]]; then
  IS_NEW_APP=1
  if [[ -z "$SLUG" || -z "$NAME" ]]; then
    echo "Error: app with bundle ID $BUNDLE_ID is not in apps.json yet. --slug and --name are required to add it." >&2
    exit 1
  fi
else
  SLUG="$(echo "$LOOKUP_OUTPUT" | sed -n '2p')"
  EXISTING_NAME="$(echo "$LOOKUP_OUTPUT" | sed -n '3p')"
  NAME="${NAME:-$EXISTING_NAME}"
fi

# --- Step 4: version/tag collision checks -------------------------------

VERSION_EXISTS="$(python3 - "$APPS_JSON" "$BUNDLE_ID" "$VERSION" <<'PYEOF'
import json, sys
apps_json_path, bundle_id, version = sys.argv[1], sys.argv[2], sys.argv[3]
with open(apps_json_path) as f:
    data = json.load(f)
app = next((a for a in data["apps"] if a.get("bundleIdentifier") == bundle_id), None)
if app is None:
    print("no")
else:
    print("yes" if any(v.get("version") == version for v in app.get("versions", [])) else "no")
PYEOF
)"
if [[ "$VERSION_EXISTS" == "yes" ]]; then
  echo "Error: version $VERSION already exists for bundle ID $BUNDLE_ID in apps.json" >&2
  exit 1
fi

TAG="${SLUG}-v${VERSION}"

if git -C "$SCRIPT_DIR" rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  echo "Error: git tag $TAG already exists locally" >&2
  exit 1
fi

set +e
git -C "$SCRIPT_DIR" ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1
REMOTE_TAG_RC=$?
set -e
if [[ "$REMOTE_TAG_RC" -eq 0 ]]; then
  echo "Error: git tag $TAG already exists on origin" >&2
  exit 1
elif [[ "$REMOTE_TAG_RC" -ne 2 ]]; then
  echo "Warning: could not check origin for existing tags (network issue?); continuing with local check only" >&2
fi

# --- Step 5: size + sha256 + icon ----------------------------------------

SIZE="$(stat -f%z "$IPA_PATH")"
SHA256="$(shasum -a 256 "$IPA_PATH" | awk '{print $1}')"
DATE="$(date +%Y-%m-%d)"
ASSET_NAME="${SLUG}-${VERSION}.ipa"
DOWNLOAD_URL="https://github.com/${REPO}/releases/download/${TAG}/${ASSET_NAME}"

ICON_IS_LOCAL_FILE=0
ICON_URL=""
if [[ -n "$ICON" ]]; then
  if [[ -f "$ICON" ]]; then
    ICON_IS_LOCAL_FILE=1
    ICON_URL="${SOURCE_BASE_URL}/icons/${SLUG}.png"
  else
    ICON_URL="$ICON"
  fi
elif [[ "$IS_NEW_APP" -eq 1 ]]; then
  ICON_URL="${SOURCE_BASE_URL}/icon.png"
fi

# --- Step 6: build the apply helper (also used to print the dry-run entry)

APPLY_HELPER="$WORKDIR/apply_entry.py"
cat > "$APPLY_HELPER" <<'PYEOF'
import json, sys

(apps_json_path, meta_json_path, mode, bundle_id, is_new_app, slug, name,
 subtitle, tint, icon_url, icon_provided, version, build, date, notes,
 download_url, size, sha256, min_os) = sys.argv[1:20]

is_new_app = is_new_app == "1"
icon_provided = icon_provided == "1"
size = int(size)

entry = {
    "version": version,
    "buildVersion": build,
    "date": date,
    "localizedDescription": notes,
    "downloadURL": download_url,
    "size": size,
    "sha256": sha256,
    "minOSVersion": min_os,
}

with open(apps_json_path) as f:
    data = json.load(f)
with open(meta_json_path) as f:
    meta = json.load(f)

if is_new_app:
    app = {
        "name": name,
        "bundleIdentifier": bundle_id,
        "developerName": "Neldasi",
        "subtitle": subtitle,
        "localizedDescription": notes,
        "iconURL": icon_url,
        "versions": [entry],
        "appPermissions": {"entitlements": [], "privacy": {}},
    }
    if tint:
        app["tintColor"] = tint
    if mode == "print":
        print("New app entry:")
        print(json.dumps(app, indent=2, ensure_ascii=False))
        print()
        print("New apps-meta.json record:")
        print(json.dumps({bundle_id: {"slug": slug}}, indent=2, ensure_ascii=False))
        sys.exit(0)
    data["apps"].append(app)
    meta[bundle_id] = {"slug": slug}
else:
    app = next(a for a in data["apps"] if a.get("bundleIdentifier") == bundle_id)
    if icon_provided:
        app["iconURL"] = icon_url
    if mode == "print":
        print("New version entry for existing app:")
        print(json.dumps(entry, indent=2, ensure_ascii=False))
        if icon_provided:
            print()
            print(f"iconURL will be updated to: {icon_url}")
        sys.exit(0)
    app.setdefault("versions", []).insert(0, entry)

with open(apps_json_path, "w") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write("\n")
with open(meta_json_path, "w") as f:
    json.dump(meta, f, indent=2, ensure_ascii=False)
    f.write("\n")
PYEOF

ICON_PROVIDED=0
[[ -n "$ICON" ]] && ICON_PROVIDED=1

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "DRY RUN - no changes made."
  echo
  echo "Bundle ID: $BUNDLE_ID"
  echo "Slug:      $SLUG"
  echo "Name:      $NAME"
  echo "Version:   $VERSION"
  echo "Build:     $BUILD"
  echo "Tag:       $TAG"
  echo "Size:      $SIZE bytes"
  echo "SHA256:    $SHA256"
  echo
  python3 "$APPLY_HELPER" "$APPS_JSON" "$APPS_META_JSON" print "$BUNDLE_ID" "$IS_NEW_APP" "$SLUG" \
    "$NAME" "$SUBTITLE" "$TINT" "$ICON_URL" "$ICON_PROVIDED" "$VERSION" "$BUILD" "$DATE" "$NOTES" \
    "$DOWNLOAD_URL" "$SIZE" "$SHA256" "$MIN_OS_VERSION"
  if [[ "$ICON_IS_LOCAL_FILE" -eq 1 ]]; then
    echo
    echo "Icon would be copied to: icons/${SLUG}.png"
  fi
  exit 0
fi

# --- Step 7: copy IPA, create the GitHub release first -------------------

RELEASE_IPA="$WORKDIR/$ASSET_NAME"
cp "$IPA_PATH" "$RELEASE_IPA"

echo "Creating GitHub release $TAG..."
gh release create "$TAG" "$RELEASE_IPA" \
  --repo "$REPO" \
  --title "$NAME $VERSION" \
  --notes "$NOTES"

# --- Step 8: copy icon if a local file was given -------------------------

if [[ "$ICON_IS_LOCAL_FILE" -eq 1 ]]; then
  mkdir -p "$SCRIPT_DIR/icons"
  cp "$ICON" "$SCRIPT_DIR/icons/${SLUG}.png"
fi

# --- Step 9: update apps.json / apps-meta.json now that the asset exists -

echo "Updating apps.json..."
python3 "$APPLY_HELPER" "$APPS_JSON" "$APPS_META_JSON" apply "$BUNDLE_ID" "$IS_NEW_APP" "$SLUG" \
  "$NAME" "$SUBTITLE" "$TINT" "$ICON_URL" "$ICON_PROVIDED" "$VERSION" "$BUILD" "$DATE" "$NOTES" \
  "$DOWNLOAD_URL" "$SIZE" "$SHA256" "$MIN_OS_VERSION"

python3 -c "import json; json.load(open('$APPS_JSON'))"
python3 -c "import json; json.load(open('$APPS_META_JSON'))"

git -C "$SCRIPT_DIR" add apps.json apps-meta.json
if [[ "$ICON_IS_LOCAL_FILE" -eq 1 ]]; then
  git -C "$SCRIPT_DIR" add "icons/${SLUG}.png"
fi
git -C "$SCRIPT_DIR" commit -m "Release $NAME $VERSION ($BUILD)"
git -C "$SCRIPT_DIR" push

# --- Step 10: summary ------------------------------------------------------

echo
echo "Release complete."
echo "App:         $NAME"
echo "Version:     $VERSION"
echo "Build:       $BUILD"
echo "Size:        $SIZE bytes"
echo "Source URL:  ${SOURCE_BASE_URL}/apps.json"
