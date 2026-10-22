# Camera Profile Builder

Native macOS app for building ARRI camera controls for Stream Deck +. Each camera becomes one named folder that can be copied into your existing profiles, with its buttons, dials, icons, live feedback, and Exposure subfolder included.

[Download the latest release](https://github.com/untitledca/Camera-Profile-Builder/releases/latest)

## Install and build

1. Open the DMG and drag **Camera Profile Builder** into Applications.
2. Open the app, choose the ARRI camera model, enter its name and IP address, and select **Test Connection**.
3. Save additional cameras the same way, then select **Build & Install**.

The app installs Camera Control, backs up your Stream Deck profiles and preferences, and activates the selected camera's profile. It also creates **Camera Folders**, a convenient place to find every saved camera folder and the GANG folder.

Requires macOS 13 or later and Stream Deck + with Stream Deck 6.6 or later. Universal Apple silicon / Intel build. Hardware verification used an ALEXA Mini LF and Stream Deck 7.4.2 on macOS 15.7.1. Other camera models and firmware need their own verification.

## Copy a camera into another profile

1. In Stream Deck, select **Camera Folders** or the individual camera profile.
2. Select the **A CAM** folder key and copy it with **⌘C** or **Copy** in its context menu.
3. Switch to your existing Stream Deck + profile, select an empty key, and paste with **⌘V** or **Paste**.

Open the pasted folder to use its controls. The nested **EXPOSURE** folder contains EI, ND, and FPS. Native Back buttons return to the folder's new parent. Copying carries the enclosed controls with it; no links to a separate camera profile are required.

Copies on the same Mac refer to the same saved camera. Editing that camera's IP in the builder updates all its copies. Camera Control must remain installed. For a different Mac, configure its cameras and generate fresh folders there; profiles do not embed camera addresses or the plugin.

## Controls and live feedback

| Dial | Turn | Press or tap |
| --- | --- | --- |
| White balance | 100 K; hold and turn for 10 K | Reset to 5600 K |
| Playback | Change playback speed | Play / pause |
| CC tint | 0.5; hold and turn for 0.1 | Reset to zero |
| Shutter angle | 0.1° | Reset to 180° |
| Exposure index | Camera's available EI choices | Reset to 800 |
| ND filter | Camera's available ND choices | Reset to clear |
| Sensor FPS | 1 fps; hold and turn for 0.1 fps | Reset to 24 fps |

The touch strip shows camera readback. Available choices, limits, and locked settings come from the camera. Unsupported controls fail visibly. Playback requires recorded clips on the camera media.

## Gang cameras

Select **GANG CAMS** or **Gang Cameras** in the builder, check the saved camera addresses, then select **Enable Gang**. All generated and copied camera controls then target that selection. **Turn Gang Off** restores individual camera control. The GANG folder always targets the checked cameras.

Turning a knob sets the selected cameras to the same semantic value, using the first checked camera in the displayed list as the starting point. **MIXED** indicates differing values. Offline cameras and rejected changes are reported. A gang operation can partially succeed and is not frame synchronized; check the cameras after an error.

## App updates

Use **Updates…** in the app to check GitHub and select **Install & Relaunch** when a newer build is available. Automatic startup checks can be enabled in the same window.

The updater requires an Ed25519 signed checksum manifest, checks the downloaded app's SHA-256 hash, validates its bundle and version, and replaces the app with a recoverable backup. After relaunch, an older installed Camera Control plugin is refreshed without regenerating profiles or changing copied camera folders.

This release is ad-hoc signed and is not Apple notarized. The updater does not remove quarantine attributes or change macOS security settings. Apple Developer signing and notarization are separate from the update signatures.

## Local data and compatibility

The camera must be reachable and its Web Remote enabled. This app uses the ARRI Web Remote HTTP interface from the original working controls; it does not provide video streaming or CAP protocol support. The camera model dropdown records the selected model; actual capabilities are read from that camera.

Configuration, generated exports, backups, and local diagnostic files are stored under `~/Library/Application Support/Camera Profile Builder/`. Camera IPs and settings stay local. Update checks contact the public GitHub release endpoint without sending camera configuration.

Donation controls and diagnostic log export are planned for a later release and are not included here.

## Build and verify

```sh
python3 scripts/build.py

swiftc -swift-version 5 Sources/CameraCore.swift tests/CameraCoreTests.swift -o /tmp/camera-core-tests
/tmp/camera-core-tests

swiftc -swift-version 5 Sources/CameraCore.swift Sources/ProfileBuilder.swift tests/ProfileBuilderTests.swift -o /tmp/camera-profile-tests
/tmp/camera-profile-tests

swiftc -swift-version 5 Sources/CameraCore.swift Sources/ProfileBuilder.swift Sources/ConfigStore.swift tests/InstallerPreferenceTests.swift -o /tmp/camera-installer-tests
/tmp/camera-installer-tests

swiftc -swift-version 5 Sources/CameraCore.swift Sources/ProfileBuilder.swift Sources/ConfigStore.swift tests/InstallerProfileTests.swift -o /tmp/camera-installer-profile-tests
/tmp/camera-installer-profile-tests

swiftc -swift-version 5 Sources/Updater.swift Sources/UpdatePublicKey.swift tests/UpdaterTests.swift -o /tmp/camera-updater-tests
/tmp/camera-updater-tests

python3 tests/plugin_integration.py
```

Tests use sanitized fixtures and isolated loopback cameras. Real camera write diagnostics require an explicit `--hardware-address` argument. The release process is described in [Publishing updates](docs/Publishing-updates.md). Release signing keys belong in the maintainer's Keychain and must not be committed.

## References and artwork

- [Stream Deck native plugin protocol](https://docs.elgato.com/streamdeck/sdk/references/websocket/plugin/)
- [Dials and touch strip](https://docs.elgato.com/streamdeck/sdk/guides/dials/)
- [Profile packaging](https://docs.elgato.com/stream-deck/profiles/packaging/)

App and plugin icons are drawn by the included Swift scripts. Camera control artwork in `assets/reference-icons` was retained from the original working A CAM profile; no separate artwork reuse license is supplied.
