# macOS distribution

## Build a local package

On macOS, run:

```sh
scripts/package.sh
```

This builds the Swift package in release mode, creates `dist/Lanebay.app`, ad-hoc
signs it with `codesign -s -`, and creates `dist/Lanebay.dmg`. The DMG contains
the app and an Applications shortcut. Ad-hoc signing is suitable for local
testing and does not identify a trusted publisher, so Gatekeeper may block the
app on other Macs. This package is not notarized.

The bundle identifier defaults to `com.lanebay.app`; set `BUNDLE_ID` and
`APP_VERSION` when packaging a release. An `.icns` file found in the repository
is copied into the app bundle. No icon is currently required for packaging.

## Sparkle configuration

Sparkle is included as a Swift Package Manager dependency. Update checking is
disabled unless both `SPARKLE_FEED_URL` and `SPARKLE_PUBLIC_ED_KEY` contain
usable release values when the app is packaged. By default the package receives
an `example.invalid` feed URL and a placeholder key; the app does not create or
start an updater with those values. Automatic checks and automatic installation
are also disabled in the generated Info.plist. A configured app offers a
**Check for Updates…** menu command.

For a real updater feed, generate and securely store a Sparkle EdDSA key pair.
Keep the private key offline or in a protected release secret store; only the
public key belongs in the app. Package with the real feed and public key:

```sh
SPARKLE_FEED_URL="https://updates.example.com/lanebay/appcast.xml" \
SPARKLE_PUBLIC_ED_KEY="<base64 public key>" \
scripts/package.sh
```

Do not use ad-hoc signed packages as production Sparkle updates. Sparkle
distribution should use a stable appcast, signed update archives, and
Developer ID signed and notarized app bundles.

## Requirements for public distribution

1. Enroll in the Apple Developer Program and obtain a **Developer ID Application** certificate for signing the app and its nested code.
2. Sign the app with hardened runtime and a secure timestamp, then submit it to Apple for **notarization** and staple the notarization ticket.
3. Generate a Sparkle **EdDSA key pair**, protect the private key, and configure the matching public key in the app bundle.
4. Host the Sparkle **appcast XML** and signed update archives at stable HTTPS URLs. Publish each release archive and appcast entry together, and retain older versions for clients that have not updated.
5. Validate installation, Gatekeeper, update signature verification, and upgrades from prior releases on a clean macOS account before announcing a release.

Apple Developer ID distribution requires a paid Apple Developer Program
membership. The build and ad-hoc DMG workflow in this repository does not
require that membership or any paid hosting service. Sparkle keys can be
generated locally; appcast hosting can be selected separately when a public
release channel is established.
