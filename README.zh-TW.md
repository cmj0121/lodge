# Lodge

> Your browser, your workspace

[English](README.md) | 繁體中文

給自己用、以 workspace 為核心的瀏覽器，支援 macOS、iOS 和 iPadOS：每個 workspace 都是一個自己的瀏覽器，
只有正在用的那一個才耗用資源。

## 概念

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

| 概念                 | 行為                                                                      |
| -------------------- | ------------------------------------------------------------------------- |
| Default workspace    | 內建的共用瀏覽器，永遠都在；pinned tab 屬於它，在每個 workspace 都能使用  |
| 自訂 workspace       | 一個新的瀏覽器：每個網站都有自己的一份網站資料與登入                      |
| 獨立的身分           | 登入、cookie 和網站資料各自保存在產生它們的 workspace 裡                  |
| 獨立的 fingerprint   | 每個 workspace 對每個網站都呈現一個不同且穩定的 fingerprint               |
| 一個頁面，一個瀏覽器 | 頁面始終屬於同一個瀏覽器；在另一個 workspace 開啟時，帶著網址過去重新開始 |
| 歸屬一目了然         | 每個頁面都顯示它屬於哪個瀏覽器                                            |
| 資源用在當下         | 先釋放，再暫停，最後休眠；回來時只喚醒畫面上的那個頁面                    |
| 進行中的工作         | 表單、播放、下載會先完成或保存，再讓出資源                                |
| 輕盈好用             | 沒在用的 workspace 安靜無聲，切換快速，回來就能接著做                     |
| Credential           | 密碼和 passkey 來自 OS 的 credential store，在每個 workspace 都能使用     |
| 三個平台             | Mac、iPhone、iPad 共用同一套規則，各自用最適合的方式操作                  |
| 清楚的承諾           | 每個 workspace 的網站資料與登入各自分開，Lodge 就照這樣說明               |

## 為什麼不用現有的瀏覽器

| 能力                            | Lodge | Chrome / Edge | Firefox            | Safari      | Arc      |
| ------------------------------- | ----- | ------------- | ------------------ | ----------- | -------- |
| 一個視窗裡多個瀏覽器            | ✅    | ⚠️ profiles   | ⚠️ 只有 containers | ⚠️ profiles | ✅       |
| 每個 workspace 都有 Default pin | ✅    | ❌            | ❌                 | ❌          | ❌       |
| 整個 workspace 一起 hibernate   | ✅    | 只有 tab      | 只有 tab           | 只有 tab    | 只有 tab |
| iOS / iPadOS 同一套模型         | ✅    | ⚠️            | ❌                 | ✅          | ⚠️       |
| 系統層 credential               | ✅    | ⚠️            | ❌                 | ✅          | ❌       |

Lodge 以 WebKit 為底，passkey、service worker 和 extension 隨 Apple 對瀏覽器開放的能力而定。

## DDD (Dream-Driven Development)

這個專案遵循 DDD（dream-driven development）：每個功能都來自我的夢想和需要。
