# Publishing The Button

How to get this into other people's hands. Three channels, in order of reach.

## 0. Prerequisite: put the repo on GitHub

```bash
cd ~/Desktop/the_button
git init && git add -A && git commit -m "The Button v0.1.0"
gh repo create the-button --public --source . --push   # or create on github.com and push
```

Then replace the two `CHANGEME` placeholders in `vscode-extension/package.json`:
- `"publisher"` → your Marketplace publisher ID (created in step 1)
- `"repository".url` → your real GitHub URL

## 1. VS Code Marketplace (the extension)

One-time setup (~15 minutes):

1. **Create a publisher**: sign in at
   https://marketplace.visualstudI io.com/manage with a Microsoft account →
   "Create publisher". The ID you pick (e.g. `charan-dev`) goes into
   `package.json` `"publisher"`.
2. **Create a token**: at https://dev.azure.com → User settings →
   Personal Access Tokens → New Token → Organization: **All accessible
   organizations**, Scopes: **Marketplace → Manage**. Copy it.

Publish (every release):

```bash
cd vscode-extension
./package.sh                                  # syncs hook.py + builds the .vsix
npx @vscode/vsce login <your-publisher-id>    # paste the token (first time only)
npx @vscode/vsce publish                      # or: publish patch|minor|major to auto-bump
```

Alternative for the first release: upload the `.vsix` manually on the
marketplace.visualstudio.com/manage page — no CLI login needed. The automated
review takes a few minutes; then anyone can install it from the Extensions
view. Until then, you can share the `.vsix` file directly — "Extensions: Install
from VSIX" works for anyone today.

## 2. Open VSX (Cursor, Windsurf, VSCodium users)

Cursor and other forks don't read Microsoft's marketplace. Open VSX covers them:

1. Sign in at https://open-vsx.org with GitHub → create a namespace matching
   your publisher ID, and generate an access token in your settings.
2. ```bash
   npx ovsx publish claude-code-the-button-0.1.0.vsix -p <open-vsx-token>
   ```

## 3. The macOS floating app

The Mac App Store is **not** an option: sandboxed apps can't post keystrokes
(CGEvent), script Terminal/iTerm2, or use the Accessibility API on other apps —
all of which are The Button's core. Distribute directly:

**Easy (free):** GitHub Releases.
```bash
./build.sh
ditto -c -k --keepParent TheButton.app TheButton-v0.1.0.zip
gh release create v0.1.0 TheButton-v0.1.0.zip --title "The Button v0.1.0"
```
Because the app is only ad-hoc signed, downloaders must bypass Gatekeeper once:
right-click → Open, or `xattr -d com.apple.quarantine TheButton.app`. Put that
in the release notes. Cloning the repo and running `./install.sh` avoids the
issue entirely (locally built apps aren't quarantined) — that's the smoothest
free path and worth featuring in the README.

**Proper (when it gets traction):** Apple Developer Program ($99/yr) →
Developer ID Application certificate → sign with hardened runtime → notarize:
```bash
codesign --force --deep --options runtime --sign "Developer ID Application: <you>" TheButton.app
ditto -c -k --keepParent TheButton.app TheButton.zip
xcrun notarytool submit TheButton.zip --keychain-profile <profile> --wait
xcrun stapler staple TheButton.app
```
Then add a Homebrew cask (own tap first: `brew tap <you>/tap`) so it's just
`brew install --cask the-button`.

## Release checklist

- [ ] Bump `version` in `vscode-extension/package.json` and `Resources/Info.plist`
- [ ] Update `vscode-extension/CHANGELOG.md`
- [ ] `./build.sh` + smoke test (`TheButton.app/Contents/MacOS/TheButton --test`)
- [ ] `vscode-extension/package.sh` + install the .vsix locally and test once
- [ ] `vsce publish`, `ovsx publish`, GitHub release with the app zip
