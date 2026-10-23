# Sparkle binary package mirror

This small local Swift package exposes Sparkle 2.10.0 through Swift Package
Manager. It downloads the upstream `Sparkle-for-Swift-Package-Manager.zip` from
the SourceForge mirror because SwiftPM stalled on the corresponding GitHub
release asset during dependency resolution. The direct download URL retains its
`.zip` suffix so SwiftPM recognizes it as a supported binary artifact. The
checksum is the upstream Sparkle 2.10.0 checksum, so the mirror must serve the
exact published archive.

When updating Sparkle, update the versioned mirror URL and checksum together
from the matching upstream `Package.swift` release manifest.
