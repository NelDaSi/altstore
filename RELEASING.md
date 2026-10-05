# Releasing to Neldasi's Apps

This repo (`~/Documents/altstore`) hosts the AltStore source for all of my
apps at `https://neldasi.github.io/altstore/apps.json`. App code repos can
stay private — only the built `.ipa` files are uploaded here, as GitHub
Release assets.

## One-command release (existing app)

1. In Xcode, bump the version (`MARKETING_VERSION`) and build number
   (`CURRENT_PROJECT_VERSION`).
2. Product > Archive, then Distribute App > export the `.ipa`.
3. From this folder, run:
   ```
   ./release.sh "<path to exported .ipa>" "<release notes text>"
   ```
   The app is found automatically by the bundle ID inside the IPA, so no
   extra flags are needed for an app that's already in `apps.json`.
   Use `--dry-run` first if you want to check the version/size/hash and see
   the exact `apps.json` entry before publishing anything.
4. Wait ~1-2 minutes for GitHub Pages to republish `apps.json`.
5. On your iPhone: open AltStore, go to Neldasi's Apps source, and refresh
   it to see the update.

## Rules

- Every release needs a **new version string** (`CFBundleShortVersionString`
  in the IPA) — the script refuses to publish a version that's already in
  `apps.json` for that app, and refuses a release tag that already exists.
- The `version` in `apps.json` must **exactly equal** the IPA's
  `CFBundleShortVersionString`, or AltStore will refuse to install/update.
  The script reads this straight from the IPA, so this is automatic as long
  as you bump `MARKETING_VERSION` before archiving.
- Build numbers (`CURRENT_PROJECT_VERSION` / `buildVersion`) are plain
  integers that only go up (1, 2, 3, …).
- Version strings look like `1.1`, `1.1.1`, `1.2`, etc.
- Release tags are `<slug>-v<version>` (e.g. `dafscanner-v1.1`), and release
  assets are named `<slug>-<version>.ipa`.
- The script always creates the GitHub release **before** touching
  `apps.json`, so `apps.json` is never left pointing at a release that
  doesn't exist yet.
- Only `apps.json`, `apps-meta.json`, and `icons/` are committed by the
  script — never an `.ipa` (they're git-ignored and live only as release
  assets).

## Adding a brand new app

Use the same script, but pass `--slug` and `--name` (both required for an
app that isn't in `apps.json` yet), plus optionally `--subtitle`, `--icon`,
and `--tint`:

```
./release.sh "<path to exported .ipa>" "<release notes text>" \
  --slug myapp --name "My App" \
  --subtitle "A short tagline" \
  --icon "/path/to/icon.png" \
  --tint "#112233"
```

- `--slug` is a short, lowercase, URL-safe identifier used for release tags,
  asset names, and the icon filename. Pick it once and keep it stable —
  it's recorded in `apps-meta.json` against the app's bundle ID so future
  releases don't need `--slug` again.
- `--icon` can be a local file (copied into `icons/<slug>.png` and served
  from `https://neldasi.github.io/altstore/icons/<slug>.png`) or a URL to
  use directly. If omitted for a new app, the shared source icon
  (`icon.png`) is used as a placeholder — pass a real one when you have it.
- `--subtitle` and `--tint` are optional; the app's description comes from
  the release notes you pass.
- Always try `--dry-run` first — it prints the new `apps.json` app entry and
  the new `apps-meta.json` record without changing anything.

After the first real release, the app is in `apps.json` and future releases
for it are just `./release.sh "<ipa>" "<notes>"` as above.
