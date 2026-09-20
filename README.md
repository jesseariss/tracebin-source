# TraceBin

Photograph one tool on US Letter or A4 paper, adjust its outline clearance and bin height, and export
a binary STL for a Gridfinity bin or flat drawer insert. This snapshot includes the finger-hole update:
one adjustable circular finger notch per Gridfinity bin, with a full-screen placement editor.

## About this source release

This is a one-time source snapshot, not a commitment to publish future versions. After publication
the repository is archived. You are welcome to fork it. Future official development is private.

The app's code was written using AI coding tools under Jesse Ariss's direction. Jesse chose the
product behavior and tested the app and prints. This is a learning project, not a claim that the
code was hand-written or independently audited. Known limitations are documented below.

## Build and run

- macOS and Xcode 27 public release (the tested baseline); iOS 17 or later; iPhone only.
- Swift 5 language mode. No Swift packages, backend, API keys or accounts are required by the app.
- Open `TraceBin.xcodeproj`, select the `TraceBin` scheme and an iPhone simulator, then Run.
- For a physical iPhone, select your own team under Signing & Capabilities for both targets. Change
  the app and test bundle identifiers to unique values you control. Never use the publisher's credentials.
- Simulator tracing is not a substitute for testing Apple's Vision models on a real phone.

Command-line checks (replace the example simulator name with one installed on your Mac):

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -list -project TraceBin.xcodeproj
xcodebuild test -project TraceBin.xcodeproj -scheme TraceBin -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
xcodebuild build -project TraceBin.xcodeproj -scheme TraceBin -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO
```

An unsigned build is a compilation check, not an App Store upload or an installable phone build.

## Architecture

All app folders below are inside `TraceBin/`.

1. `Camera/` and `Support/ImageLoader.swift` acquire an image locally.
2. `Engine/TraceEngine.swift` detects paper, corrects perspective and extracts the tool outline.
3. `Models/` carries trace settings and SwiftData history; `Views/` presents capture, adjustment,
   full-screen notch editing and 3D preview.
4. `Engine/BinBuilder.swift`, `FingerNotch.swift`, and `Geometry2D.swift` construct the printable mesh.
5. `Engine/STLWriter.swift` writes the binary STL for the iOS share sheet.

`Reference/binforge.py` is the geometry reference; Swift follows its function structure.
Python is not needed to build the app. The reference's executable synthetic-wrench example requires
NumPy and OpenCV; mesh-only functions use NumPy. See `Reference/README.md` for fixture provenance.
These Python packages are not bundled into the iOS app.
`TraceBinTests/` contains geometry, editor-state, persistence, paper-size and decorative-logo tests.

## Limits and testing

- One tool per photo and one circular notch per Gridfinity bin. Flat inserts do not include notches.
- A notch must fit the existing bin; unsafe placements are rejected rather than silently omitted.
- Reflective tools, shadows and incomplete paper edges can affect tracing. Inspect the outline and
  slicer preview, and print a fit test before relying on a large part.
- Existing saved-bin notch changes save with Done; Cancel discards the draft. New bins enter history
  through STL sharing.
- Multiple tools, labels, magnet holes and 3MF export are not included in this snapshot.

The app makes no network requests and contains no analytics. Saved outlines, settings and thumbnails
remain on the device. DEBUG builds have additional diagnostics; do not share their captured photos/logs
without checking them. Exports handed to another app are subject to that app's privacy practices.

## Support and license

[Support](https://jesseariss.github.io/tracebin/) ·
[Privacy](https://jesseariss.github.io/tracebin/privacy) ·
[Roadmap](https://tracebin.app/)

Report ordinary bugs in the support page's Reddit discussion, without personal information. This
archived snapshot does not accept issues or pull requests. Forks are independently maintained.

MIT license; see `LICENSE` and `THIRD-PARTY-NOTICES.md`. Attribution does not imply endorsement by
the Gridfinity creators or community.
