# SideStore Connect

Each published GitHub release puts its iPad IPA into the WiredDisplay source on SideStore Connect (https://connect.sidestore.io). SideStore users can then install and update the iPad app from there.

- `.github/workflows/sidestore.yml` runs on every published release that is not a pre-release. It can also be run by hand ("Run workflow", with a tag).
- `scripts/sidestore-publish.sh <tag>` does the work. It sends SideStore Connect the release asset's GitHub download URL and size, so the IPA is not uploaded a second time.

## Adding the source in SideStore
SideStore Connect has one shared source for every app on the instance: `https://connect.sidestore.io`. SideStore is redirected to `/apps.json`. In SideStore, open Sources, tap +, and paste that URL. WiredDisplay is listed only once a version is published.

The app's build setting in the dashboard is "GitHub Releases" (sibawono / WiredDisplay). SideStore Connect then imports the release that matches the current version from time to time, and the dashboard has a synchronize button. This workflow also creates each new version, so a release does not need a version made by hand first.

Store listing text, the icon and the 2360 x 1640 iPad screenshots: `docs/share/SIDESTORE-LISTING.txt` and `docs/share/sidestore/`.

## Why not `SideStore-Connect/action`
The documented action (last change March 2024) cannot run as published:
- its repository has no `node_modules` and no bundle, so `axios` cannot be loaded;
- `index.js` uses a top-level `await` in a CommonJS file;
- it declares `node16`.

It also posts a multipart form to `/api/webhook/apps/<id>/version/<version>`, while the API page (`/docs/developer/webhooks/apps`) documents a JSON body on that endpoint. The script follows the API page. See D-044.

## One-time setup (the owner)
1. Sign in at https://connect.sidestore.io, for example with "Sign in with GitHub".
2. Create the app with bundle ID **`dev.wireddisplay.client`** (done 2026-11-25; in review). This is the bundle ID of the released IPA (`scripts/build-ipa.sh`), not the local one from `LOCAL-HANDOVER.md`. Add the name, icon, description and screenshots there.
3. Create a Personal Access Token (done): User Settings → Access Tokens → +. It is shown only once.
4. On GitHub (sibawono/WiredDisplay → Settings → Secrets and variables → Actions):
   - add the secret **`SIDESTORE_ACCESS_TOKEN`** with that token;
   - optional variables:
     - `SIDESTORE_PUBLISH` = `true` makes each new version live at once. Without it, the version waits unpublished in the dashboard.
     - `SIDESTORE_BUNDLE_ID` sets another bundle ID.
     - `SIDESTORE_LANG` sets the description language (default `en`).
5. To send the current release: Actions → SideStore Connect → Run workflow, tag `v0.5.2`.

Without the secret, the workflow ends with a warning and sends nothing.

## What is sent
`POST /api/webhook/apps/dev.wireddisplay.client/version/<version>` with `Authorization: Bearer <token>` and:
- `allowCreateNewVersion: true`
- `versionDescription: {"en": <release notes without the "## Downloads" section>}`
- `externalDownloadUrl`: `https://github.com/sibawono/WiredDisplay/releases/download/<tag>/WiredDisplay-<version>.ipa`
- `downloadFileSize`
- `publish` (from `SIDESTORE_PUBLISH`)

Before it sends anything, the script checks these:
- The tag is a version tag.
- The release is not a draft. A pre-release is skipped.
- There is exactly one `.ipa`, named `WiredDisplay-<version>.ipa`.
- The public download returns the same number of bytes as the release lists.

Check without sending: `DRY_RUN=1 scripts/sidestore-publish.sh v0.5.2`.

## Not verified
- No real token was used yet. Without a valid token, the endpoint answers 401, and with a malformed one 422 (`Not enough segments`), so the route exists.
- The docs do not say whether the app must exist before the first call, or which language codes the app accepts. If the first run fails, the job log shows SideStore Connect's answer.
