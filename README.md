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
| Own identity          | Sign-ins, cookies and site data stay in the workspace they were made in                  |
| Own fingerprint       | Every workspace presents a distinct, stable fingerprint to each site                     |
| Own history           | Each browser keeps the pages visited in it; Anonymous keeps none                         |
| One page, one browser | A page stays in its browser; opening it in another workspace carries the address there   |
| Clear ownership       | Every page shows which browser it belongs to                                             |
| Resources for now     | Release first, then suspend, then hibernate; coming back wakes only the page on screen   |
| Work in progress      | Forms, playback and downloads finish or are saved before their resources are handed back |
| Light to use          | Idle workspaces stay quiet, switching is quick, and you pick up where you left off       |
| Several windows       | ⌘N opens a window on the same workspaces; each shows its own tab and returns on relaunch |
| Default browser       | Settings › General makes Lodge the default; links from other apps open in a Default tab  |
| Credentials           | Passwords and passkeys come from the OS credential store, ready in every workspace       |
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

## DDD (Dream-Driven Development)

This project follows DDD (dream-driven development): every feature is built from what I dream of and need.
