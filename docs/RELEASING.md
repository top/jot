# Releasing Jot

GitHub Actions builds a universal (Apple Silicon and Intel) DMG without an
Apple Developer account, signing certificate, notarization credentials, or
repository secrets. The app uses bundle ID `org.ie9.app` and ad-hoc signing.
Ad-hoc signing provides no verified developer identity; neither the app nor
the DMG is notarized by Apple.

## Publish a release

1. Enable GitHub Actions in the fork. Repository or organization policies must
   allow the workflow's `contents: write` permission.
2. Update `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml`,
   commit the changes, and push them.
3. Push a matching version tag, for example:

   ```bash
   git tag v0.4.0
   git push origin v0.4.0
   ```

The Release workflow runs for `v*` tags and attaches
`Jot-<version>-UNNOTARIZED.dmg` to the GitHub Release. It also uploads a
`Jot-DMG` Actions artifact. Keep the tag version equal to `MARKETING_VERSION`.

For a test package without publishing, choose **Actions > Release > Run
workflow** on a branch. Download `Jot-DMG` from the completed run. Manual runs
on tags also publish to that tag's release.

Normal branch pushes use the existing CI workflow for tests and a Debug build;
only pushes to `main` and pull requests trigger CI. These do not publish
releases. Creating a tag locally does nothing until you push it to GitHub.

## Local packaging

The workflow and local packaging use the same script:

```bash
./scripts/release.sh
```

It builds the universal Release app, applies ad-hoc signing and packages
`build/release/Jot-<version>-UNNOTARIZED.dmg`. No signing or notarization
credentials are needed. For local app testing without a DMG, use
`./scripts/build.sh` instead.

## Install an unnotarized build

Drag Jot into Applications before opening it. Gatekeeper may block the first
launch. For a build from a source you trust, try opening it once, then use
**System Settings > Privacy & Security > Open Anyway**, if macOS offers it.
Managed Macs may prohibit this override. Do not disable Gatekeeper globally.

Grant microphone and Accessibility access when prompted. The fork's new bundle
ID requires its own permissions; ad-hoc-signed updates may require granting
Accessibility access again. Avoid running the original Jot and this fork
together: both retain the Jot name and `jot://` URL scheme.

## Verify before distribution

Confirm CI tests pass, download the DMG, and smoke-test installation,
onboarding, permissions, dictation, and History retry. The workflow's syntax
can be checked locally, but packaging and launch behavior need a successful
GitHub macOS runner build and an installation test.
