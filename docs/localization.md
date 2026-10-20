# App localization

ASC Bridge uses Apple's native String Catalogs (`.xcstrings`) for text shown by
the macOS app. English (`en`) is the source and default language. The app currently
ships English only; the catalogs provide a place to add reviewed translations later.

The `ASCBridge` target owns the SwiftUI catalog, while `BridgeCore` owns shared
app messages such as credential and connection errors. SwiftUI strings use
`Text(_:bundle:)`, and other strings use `String(localized:bundle:comment:)`, with
the package target's `Bundle.module`. Each target must have its own catalog because
SwiftPM keeps resources in target-specific bundles. The app build includes both
bundles and derives `CFBundleLocalizations` from the locales compiled into the
app catalog.

## Editing text

Use English source text as the key and value, and add a translator comment that
explains the context. Keep phrases complete so a translator can reorder words.
Preserve interpolation placeholders and provide plural variations where needed.
Do not localize MCP method names, JSON keys, API enum values, filenames, URLs,
user-provided App Store metadata or text returned by Apple; those are protocol,
external or user content rather than app interface copy.

Build with Swift Build before syncing. Its native localization backend compiles
String Catalogs, while SwiftPM's older backend only copies the `.xcstrings` files.
Swift Build is the preview backend in Swift 6.3 and the default in Swift 6.4, so
use the explicit flag with both supported toolchains:

```sh
swift build --build-system swiftbuild
python3 scripts/localizations.py sync
```

The sync command uses Apple's compiler-generated typed localization data to add
newly discovered source strings to both catalogs. It does not translate text or
automatically update source catalogs during an ordinary build. Review every new
English value, translator comment, placeholder and plural variation in Xcode,
then run the coverage check after a debug build:

```sh
swift build --build-system swiftbuild
python3 scripts/localizations.py check
```

`./scripts/check.sh` runs the test suite, debug localization coverage check,
release build and loopback smoke checks together.

## Adding a language

Open the Swift package in Xcode and add the language to both
`Sources/ASCBridge/Resources/Localizable.xcstrings` and
`Sources/BridgeCore/Resources/Localizable.xcstrings`. Translate each applicable
entry and review it in context. Keep the English source values intact. Build and
test the app, then use `./scripts/build-app.sh` to package the compiled resources;
that script updates the final app's `CFBundleLocalizations` from the locales in
the compiled app catalog and checks that English resources are present in both
target bundles. After changing translations, rebuild the app so its locale metadata
matches the compiled catalog.

Apple's documentation: [String Catalogs](https://developer.apple.com/documentation/xcode/localizing-and-varying-text-with-a-string-catalog),
[localizing package resources](https://developer.apple.com/documentation/xcode/localizing-package-resources),
and [bundling Swift package resources](https://developer.apple.com/documentation/xcode/bundling-resources-with-a-swift-package).
