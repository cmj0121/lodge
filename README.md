# Lodge

> Your browser, your workspace

English | [繁體中文](README.zh-TW.md)

A self-use, workspace-first browser for macOS, iOS and iPadOS: one shared identity underneath, per-workspace
identities on top, and near-zero cost for the workspaces you leave.

## Concept

```text
┌───────────────────┐   ┌───────────────────┐   ┌───────────────────────┐
│ Default workspace │   │    Workspace B    │   │      Workspace A      │
└─────────┬─────────┘   └─────────┬─────────┘   └───┬───────────────┬───┘
          │                       │                 │               │
      all sites               all sites        other sites     github.com
          │                       │                 │               │
          ▼                       ▼                 ▼               ▼
┌───────────────────────────────────────────────────────────┐ ┌─────────────┐
│                  Global store · account X                 │ │   Store A   │
│                 shared by every workspace                 │ │  account Y  │
└───────────────────────────────────────────────────────────┘ └─────────────┘
```

| Concept            | Behavior                                                                                  |
| ------------------ | ----------------------------------------------------------------------------------------- |
| Default workspace  | Always there; uses the global store, so its sign-ins and site data are shared by all      |
| Workspace          | Its bindings over Default: bound sites use its store, the rest is global (A: GitHub is Y) |
| One tab, one store | Stores never merge; links, redirects, popups and sign-ins stay in the tab's store         |
| Switching          | The workspace you leave hibernates; coming back reloads only the tab on screen            |
| Moving a tab       | Only the tab moves; cookies, sessions and site data stay; reopens under the new identity  |
| Credentials        | Passwords and passkeys stay in the OS credential store, shared by all workspaces          |

## Why not an existing browser

| Capability                            | Lodge | Chrome / Edge | Firefox            | Safari   | Arc      |
| ------------------------------------- | ----- | ------------- | ------------------ | -------- | -------- |
| Global identity under every workspace | ✅    | ❌            | ⚠️ containers only | ❌       | ❌       |
| Hibernate a whole workspace           | ✅    | tab only      | tab only           | tab only | tab only |
| Same model on iOS / iPadOS            | ✅    | ⚠️            | ❌                 | ✅       | ⚠️       |
| System-level credentials              | ✅    | ⚠️            | ❌                 | ✅       | ❌       |

Trade-off: built on WebKit, so passkeys, service workers and extensions are limited until Apple grants the browser
entitlement.

**Non-goals:** merging cookies or moving sessions, notifications, and sync (planned later, serverless).

## DDD (Dream-Driven Development)

This project follows DDD (dream-driven development): every feature is built from what I dream of and need.
