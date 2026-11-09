# Lodge

> Your browser, your workspace

[English](README.md) | 繁體中文

給自己用、以 workspace 為核心的瀏覽器，支援 macOS、iOS 和 iPadOS：底下是一個共用的身分，每個 workspace 疊上自己的身分；
切走的 workspace 幾乎不耗資源。

## 概念

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

| 概念                | 行為                                                                                         |
| ------------------- | -------------------------------------------------------------------------------------------- |
| Default workspace   | 永遠存在，直接用 global store；這裡的登入和網站資料所有 workspace 共用                       |
| Workspace           | 在 Default 之上疊自己的綁定表：綁定的 site 用自己的 store，其餘走 global（A 裡 GitHub 是 Y） |
| 一個 tab 一個 store | store 永遠不合併；連結、redirect、popup 和登入流程都留在這個 tab 的 store                    |
| 切換                | 離開的 workspace 會 hibernate；切回來時只重新載入畫面上的 tab                                |
| 搬 tab              | 只搬 tab 本身，cookie、session 和網站資料留在原地；用目的地的身分重新開啟                    |
| Credential          | 密碼和 passkey 留在 OS 的 credential store，所有 workspace 共用                              |

## 為什麼不用現有的瀏覽器

| 能力                              | Lodge | Chrome / Edge | Firefox            | Safari   | Arc      |
| --------------------------------- | ----- | ------------- | ------------------ | -------- | -------- |
| 每個 workspace 底下都有共用的身分 | ✅    | ❌            | ⚠️ 只有 containers | ❌       | ❌       |
| 整個 workspace 一起 hibernate     | ✅    | 只有 tab      | 只有 tab           | 只有 tab | 只有 tab |
| iOS / iPadOS 同一套模型           | ✅    | ⚠️            | ❌                 | ✅       | ⚠️       |
| 系統層 credential                 | ✅    | ⚠️            | ❌                 | ✅       | ❌       |

代價：Lodge 以 WebKit 為底，Apple 核准瀏覽器的 entitlement 之前，passkey、service worker 和 extension 都會受限。

**不做的事：** 合併 cookie、搬 session、notification，以及同步（之後再做，不需要 server）。

## DDD (Dream-Driven Development)

這個專案遵循 DDD（dream-driven development）：每個功能都來自我的夢想和需要。
