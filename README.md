# Hermes IPA (unsigned)

Minimal iOS wrapper for the Hermes dashboard: SwiftUI + WKWebView on
`https://dash.thewhome.top/chat`. `/chat` is what reopens the last chat session, so the
app always lands back in the current conversation.

GitHub Actions builds it on a macOS runner and uploads `Hermes-unsigned.ipa`
(no signing identity needed — `CODE_SIGNING_ALLOWED=NO`).

## Sign it yourself

1. Download `Hermes-unsigned.ipa` from the workflow run's Artifacts.
2. Sign it with xsign (bundle id `top.thewhome.hermes`).
3. Install the signed IPA on the device.

## Local build (needs a Mac)

    brew install xcodegen
    xcodegen generate
    xcodebuild -project Hermes.xcodeproj -scheme Hermes -configuration Release \
      -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
