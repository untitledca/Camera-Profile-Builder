# Publishing Camera Profile Builder updates

Releases live at <https://github.com/untitledca/Camera-Profile-Builder/releases>.
The app checks the latest stable release. Keep each release's versioned installer
URLs immutable; never replace an existing installer with different bytes.

## Update signing key

The app verifies the detached Ed25519 signature on `SHA256SUMS.txt` with its
embedded public key before trusting installer hashes. The private key stays in
the release Mac's login Keychain, under service
`com.atomfilmlab.camera-profile-builder.updates`, account `Ed25519`. It is never
included in source, the app, or a release asset.

For the **first release only**, run:

```sh
swift scripts/update_signing.swift public-key
```

This reads the existing key or creates it if absent, and prints only its public
key in Base64. Embed that public key in `Sources/UpdatePublicKey.swift` before
building the first release. Keep using the same Keychain item and public key for
every later release. `sign` deliberately refuses to create a missing key.

Preserve the release Mac and securely back up its Keychain. If the key is lost,
previously installed apps cannot authenticate updates signed by a replacement.
Do not run `public-key` on a new release Mac as a substitute for restoring the
original key. This update signature is separate from Apple Developer ID signing
and notarization.

## Build and publish

1. Increase `VERSION`; the build sets the app and plugin versions together.
   The app must keep the same
   bundle identifier and embedded update public key.
2. Run the automated tests and `python3 scripts/build.py`. Verify the universal
   app and its Stream Deck folder behavior locally. Use the final versioned DMG
   and ZIP produced by the build; do not change either after hashing.
3. Generate `SHA256SUMS.txt` for those exact DMG and ZIP filenames. Keep this
   standard format: one lowercase SHA-256 digest, two spaces, and the filename on
   each line. Include a newline at the end of each line.
4. Sign the final checksum file, then independently verify it using the public
   key embedded in the built app:

   ```sh
   swift scripts/update_signing.swift sign dist/SHA256SUMS.txt
   swift scripts/update_signing.swift verify dist/SHA256SUMS.txt dist/SHA256SUMS.txt.sig PUBLIC_KEY_BASE64
   ```

   Replace `PUBLIC_KEY_BASE64` with the app's public key. The signature is a
   Base64 text file. Never publish the private Keychain item or private key data.
5. Commit and tag the tested source as `vVERSION`. Create a draft release for that
   tag and upload the versioned universal DMG, versioned universal ZIP,
   `SHA256SUMS.txt`, and `SHA256SUMS.txt.sig` together. Verify every uploaded asset
   against its local bytes, then publish the release as the latest stable release.
6. Check the unauthenticated latest-release API and download URLs. Confirm the
   release is neither a draft nor a prerelease and that the downloaded checksum
   file, detached signature, and installer pass signature and hash verification.

After publishing, run the optional end-to-end GitHub integration check:

```sh
swiftc -swift-version 5 Sources/Updater.swift Sources/UpdatePublicKey.swift tests/UpdaterTests.swift -o /tmp/camera-updater-tests
/tmp/camera-updater-tests --github-install-integration "build/Camera Profile Builder.app"
```

This explicitly contacts the public latest-release endpoint, downloads its
signed update, and tests validation, replacement, and backup using temporary
app copies. It does not launch apps or change the installed app, camera
configuration, or Stream Deck profiles. The normal test invocation remains
offline; this optional check requires a complete published stable release.

If any installer bytes change, recompute and re-sign the checksum file before
publishing. After publication, make a new version instead of replacing assets.
Keep prereleases separate from stable updates.

The build independently links the app and Stream Deck plugin, and checks that
their Mach-O UUIDs differ for each architecture. Keep this check enabled:
copying one executable into both locations can confuse macOS Local Network
privacy identity tracking, as described in [Apple TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy).
Both executables still require their normal code-signature verification. The
published 2.1.0 assets remain immutable; this correction ships in 2.1.1.

## Continuous integration

CI can test and build on a current macOS runner while targeting macOS 13 for both
Apple silicon and Intel. The `Build and test` workflow runs the camera core,
portable profile, installer preference, profile preparation and rollback,
updater, and simulated native-plugin
checks. It saves the tested DMG, ZIP, and unsigned checksum file as workflow
artifacts for 14 days; it does not create or publish a GitHub release.

CI must not generate a signing identity or publish unsigned checksums as an
update. Perform release signing on the release Mac, then upload the complete
verified asset set. No private key or additional GitHub token is required in
repository files or CI secrets for local release signing.

The signing helper can be typechecked without touching Keychain:

```sh
swiftc -swift-version 5 -target arm64-apple-macos13.0 -typecheck scripts/update_signing.swift
swiftc -swift-version 5 -target x86_64-apple-macos13.0 -typecheck scripts/update_signing.swift
```
