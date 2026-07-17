# AlembicRewrite

Select text in any macOS app, press a hotkey, and it rewrites in place through Claude or OpenAI, in a style you define. A native menu-bar tool that is local-first and bring-your-own-key.

<p align="center">
  <img src="site/assets/appicon.png" alt="AlembicRewrite" width="120">
</p>

## What it does

You highlight text anywhere on your Mac, press a key, and the selection is replaced with a rewritten version. No window to switch to, no copy and paste. Every style is yours to shape: its own prompt, its own model, its own hotkey.

## Features

- **Silent, instant rewrite.** Press `Cmd+Shift+R` and the selected text is replaced in place. Your clipboard is always restored afterwards.
- **Style palette.** Press `Cmd+Shift+E` for a searchable palette of all your styles. Type to filter, arrow to choose, Return to run.
- **Review and iterate.** For styles set to review first, a panel shows the original beside the rewrite. Iterate with a follow-up instruction, then accept.
- **Unlimited custom styles.** Each style has its own prompt template, provider (Claude or OpenAI), model, temperature, and optional direct hotkey.
- **The AlembicRewriter style.** The flagship default style turns a rough prompt into an effective one using the Directional Prompting method.
- **Running cost meter.** Tracks spend across your rewrites so you can see what your BYO key is costing.
- **Local-first.** API keys, history, and styles live only on your Mac. Requests go straight from your machine to Anthropic or OpenAI, with no vendor server in between.
- **Liquid-glass native UI.** Built in SwiftUI. Frosted glass for chrome, solid opaque panes for anything you read or type.

## Install (from Releases)

1. Download `AlembicRewrite.dmg` from the [latest release](https://github.com/rightin2/AlembicRewrite/releases/latest/download/AlembicRewrite.dmg) (about 6.9 MB, macOS 14 Sonoma or later).
2. Open the DMG and drag **AlembicRewrite** into your Applications folder.
3. **First launch:** because the app is not notarised through the App Store, macOS blocks it once. Double-click the app, let macOS refuse it, then open **System Settings > Privacy & Security**, scroll down, and click **Open Anyway** next to the AlembicRewrite message. On macOS 14 (Sonoma) you can instead right-click the app and choose **Open** twice. Either way, once only.
4. Grant **Accessibility** permission when prompted. This is how the app reads your selection and pastes the rewrite back.
5. Open **Settings** from the menu-bar icon and paste an Anthropic or OpenAI API key into the API Keys tab.
6. Select some text, press `Cmd+Shift+R` for an instant rewrite, or `Cmd+Shift+E` to pick a style.

## Build from source

Requirements: macOS 14 or later and a recent Swift toolchain (Xcode command line tools).

```bash
git clone https://github.com/rightin2/AlembicRewrite.git
cd AlembicRewrite

# build the binary
swift build -c release

# assemble AlembicRewrite.app (bundles the binary, Info.plist, and icon)
./scripts/make-app.sh

# optional: package a distributable disk image
./scripts/make-dmg.sh
```

`make-app.sh` produces `AlembicRewrite.app`; `make-dmg.sh` wraps it into `dist/AlembicRewrite.dmg`.

## Privacy

AlembicRewrite is local-first and bring-your-own-key.

- There are no accounts and no subscription. The app talks directly to Anthropic or OpenAI using a key you supply, so you pay those providers for exactly what you use.
- Your API keys, rewrite history, and custom styles are stored only on your Mac.
- No client text is routed through any server the app's author controls. Rewrite requests go device-direct to your chosen provider.

## Screenshots

A full walkthrough of the interface, including the style palette and review panel, lives on the landing page in [`site/`](site/index.html). Open `site/index.html` in a browser to view it.

Screenshots of the running app will be added here.

## Notes

AlembicRewrite is a personal tool, shared as-is with no warranty and no support commitment. It is not affiliated with Anthropic or OpenAI.
