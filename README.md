# Lodge

> Your browser, your workspace

English | [繁體中文](README.zh-TW.md)

A self-use, workspace-first browser for macOS, iOS and iPadOS: every workspace is a browser of its own, and only the
one you are in uses resources.

## Concept

```text
┌────────────────────────┐   ┌────────────────────────┐   ┌────────────────────────┐
│   Default workspace    │   │      Workspace A       │   │      Workspace B       │
│    built-in browser    │   │    its own browser     │   │    its own browser     │
└───────────┬────────────┘   └───────────┬────────────┘   └───────────┬────────────┘
            │                            │                            │
            ▼                            ▼                            ▼
┌────────────────────────┐   ┌────────────────────────┐   ┌────────────────────────┐
│     Default store      │   │        Store A         │   │        Store B         │
│ pinned tabs live here  │   │  sign-ins · site data  │   │  sign-ins · site data  │
└────────────────────────┘   └────────────────────────┘   └────────────────────────┘
```

| Concept               | Behavior                                                                                 |
| --------------------- | ---------------------------------------------------------------------------------------- |
| Default workspace     | The built-in shared browser, always there; pinned tabs belong to it, at hand everywhere  |
| Custom workspace      | A new browser: every site gets its own site data and sign-ins                            |
| Anonymous workspace   | Always last; each tab is its own browser, gone with the tab; only bookmarks are kept     |
| Anonymous look        | An unknown-person icon; windows go deep charcoal (not pages); the address shows a badge  |
| Workspace color       | Pick one of eight colors or none in the workspace sheet; it tints the sidebar and focus  |
| Sidebar header        | Default and Anonymous show a one-line tagline under their name; custom ones show none    |
| Own identity          | Sign-ins, cookies and site data stay in the workspace they were made in                  |
| Own fingerprint       | Every workspace presents a distinct, stable fingerprint to each site                     |
| Own history           | Each browser keeps its visits; Show All History lists them in a tab; Anonymous none      |
| One page, one browser | A page stays in its browser; opening it in another workspace carries the address there   |
| Clear ownership       | Every page shows which browser it belongs to                                             |
| Resources for now     | Unseen tabs and workspaces you left give their pages back; only the page on screen wakes |
| Resting tabs          | Dimmed in the sidebar, noted resting; selecting it brings back its page, history, scroll |
| Rest tabs after       | Settings › General: 5, 15, 30, 60 minutes or Never; 5 minutes by default, all workspaces |
| Places on disk        | Back after relaunch with history and scroll; a tab that sent a form gets address, scroll |
| Low memory            | When macOS runs low, unseen tabs rest at once, oldest first; you stay signed in to sites |
| Work in progress      | Unsent text, form uploads, playback, camera or mic, fullscreen, popups keep a page awake |
| Asks before leaving   | A page that would ask before you leave is kept too, best effort; downloads always finish |
| Nothing leaves        | Telling a page has unsent work reads no field contents and sends nothing out of the page |
| Light to use          | Idle workspaces stay quiet, switching is quick, and you pick up where you left off       |
| Several windows       | ⌘N opens a window on the same workspaces; each shows its own tab and returns on relaunch |
| Lodge pages           | `lodge://settings` and `lodge://history` open in a tab, one per workspace; sites can't   |
| Settings tab          | ⌘, or the gear opens it: General, Search, Downloads, About (version, macOS, data folder) |
| Search engine         | Each workspace searches with its own; pick it under Search Engine… in the workspace menu |
| Default's engine      | Settings › Search picks it; custom ones follow it until they pick; Anonymous: DuckDuckGo |
| Added engines         | Add Engine… in Settings › Search or the Search Engine… sheet: name, address `…?q=%s`     |
| Edit and remove       | Each added engine has Edit and Remove there; built-in engines stay as they are           |
| Shared engines        | Engines added in Settings › Search can be picked in every workspace, Anonymous included  |
| Removed engine        | Workspaces on it fall back: custom to Default's, Default and Anonymous to DuckDuckGo     |
| Search words          | Results pages show the words beside the engine's icon and name; Return searches again    |
| Copy address          | Copy and Copy Address still give the page's full URL while the words are unedited        |
| Suggestions           | Typing in the address bar or Open Location lists a search, tabs, bookmarks and history   |
| Local only            | Only this workspace's tabs, bookmarks and history; suggestions never touch the network   |
| Pick a suggestion     | ↑/↓ moves through the list, Return opens the selection, Esc closes the list              |
| Inline completion     | The field completes to the top suggestion; → accepts it, deleting drops it               |
| Default browser       | Its General section makes Lodge the default; links from other apps open in a Default tab |
| Credentials           | Passwords and passkeys come from the OS credential store, ready in every workspace       |
| English and 繁體中文  | Follows macOS or Language & Region › Applications; workspace names stay English          |
| Three platforms       | Mac, iPhone and iPad share one set of rules, each with the controls that suit it         |
| Clear promise         | Each workspace keeps its own site data and sign-ins, and Lodge says exactly that         |

## Why not an existing browser

| Capability                      | Lodge | Chrome / Edge | Firefox            | Safari      | Arc      |
| ------------------------------- | ----- | ------------- | ------------------ | ----------- | -------- |
| Many browsers in one window     | ✅    | ⚠️ profiles   | ⚠️ containers only | ⚠️ profiles | ✅       |
| Default pins in every workspace | ✅    | ❌            | ❌                 | ❌          | ❌       |
| Hibernate a whole workspace     | ✅    | tab only      | tab only           | tab only    | tab only |
| Same model on iOS / iPadOS      | ✅    | ⚠️            | ❌                 | ✅          | ⚠️       |
| System-level credentials        | ✅    | ⚠️            | ❌                 | ✅          | ❌       |

Built on WebKit, so passkeys, service workers and extensions follow what Apple opens to browsers.

## Publish

`make publish` ships Lodge with fastlane: a TestFlight build and a notarized Developer ID DMG, published on a GitHub
Release when `GITHUB_REPOSITORY` is set.

Set it up once:

1. Install fastlane: `bundle install`.
2. Copy the settings and fill them in: `cp .env.example .env`. Every key is listed in `.env.example` with a comment;
   values exported in the shell win over the file. Sign in to App Store Connect one of two ways:
   - API key, used whenever it is complete and never asks a person: `ASC_KEY_ID`, `ASC_ISSUER_ID` and the key file
     `AuthKey_<ASC_KEY_ID>.p8` in `~/.appstoreconnect/private_keys/` (`~/private_keys`, `~/.private_keys` and
     `./private_keys` are searched too), or `ASC_KEY_PATH` set to its path; a relative `ASC_KEY_PATH` is resolved from
     the repo root. `private_keys/` and `*.p8` are git-ignored. The App Manager role is enough for normal runs
     (read-only match, profiles, the TestFlight upload).
   - Apple ID, otherwise: `APPLE_ID` and `FASTLANE_APPLE_APPLICATION_SPECIFIC_PASSWORD`, an app-specific password from
     appleid.apple.com used only for notarizing and the TestFlight upload. The build-number lookup, the TestFlight
     sign-in and match creating certificates sign in with the Apple ID account password: fastlane asks for it once on
     the first run, then for the second factor, and keeps it in the login keychain (entry `deliver.<APPLE_ID>`), so a
     machine that has run fastlane before, even for another project, does not ask again. `FASTLANE_PASSWORD` can
     supply it instead, but the keychain is preferred. The second factor comes back about monthly; the session is
     cached in `~/.fastlane/spaceship`.
   - The GitHub Release is optional and switched on by setting `GITHUB_REPOSITORY` in `.env`; `GITHUB_TOKEN` is then
     required. A `GITHUB_TOKEN` exported in the shell alone does not turn it on.
3. `fastlane match` uses the team's shared private repo set in `MATCH_GIT_URL` (branch `main`, set in
   `fastlane/Matchfile`); match keeps apps apart by bundle ID, so there is no new repo to create.
   - Leave `MATCH_PASSWORD` unset or empty: on a machine that has run match before, match reads the passphrase from the
     login keychain. Only a machine without that keychain entry needs it.
   - The first run needs `MATCH_READONLY=false` in `.env` so match can create what is missing; set it back to `true`
     afterwards. The shared repo likely has the App Store and Mac installer certificates already, so the first run
     mainly creates the Lodge profiles and the Developer ID certificate.
   - With an API key, creating a certificate may need an Admin key, and a Developer ID certificate may need the
     Account Holder. With an Apple ID, it follows the account's role: the Account Holder can create Developer ID
     certificates. If match cannot create one, create it in Xcode (Settings → Accounts → Manage Certificates), export a
     `.p12` and run `bundle exec fastlane match import --type <type> --platform macos`, with `<type>` one of
     `appstore`, `mac_installer_distribution` or `developer_id`.
4. Create the app record for the bundle ID (`APP_IDENTIFIER`) in App Store Connect; the upload needs it to exist first.

Then publish:

| Command              | What it does                                                                                 |
| -------------------- | -------------------------------------------------------------------------------------------- |
| `make publish-check` | Checks `.env`; names missing keys, and what each sign-in way lacks when neither is complete  |
| `make publish`       | Runs `make test` and the `.env` check, then the iOS/iPadOS lanes and the macOS publish below |

The iOS and iPadOS lanes skip while `Lodge.xcodeproj` has no such target. The macOS lane (`mac publish`):

1. requires a clean tree with `HEAD` at `origin/main`: commit and push first;
2. uploads the Mac App Store pkg to TestFlight;
3. builds a notarized Developer ID DMG into `build/fastlane/` and, with `GITHUB_REPOSITORY` set, publishes it on the
   GitHub Release `v<version>`; without it the release is skipped and the DMG stays in `build/fastlane/`;
4. adds the tag `v<version>` locally; it is not pushed.

Bump `MARKETING_VERSION` before each publish: `mac publish` stops before building when the tag `v<version>` already
exists, and, with the release on, when the GitHub Release `v<version>` exists. A rerun after a failure uses a new build number.

Changing `APP_IDENTIFIER` from `dev.lodge.Lodge` gives the app a new sandbox container, so the saved session does not
carry over.

## DDD (Dream-Driven Development)

This project follows DDD (dream-driven development): every feature is built from what I dream of and need.
