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

| 概念                 | 行為                                                                                    |
| -------------------- | --------------------------------------------------------------------------------------- |
| Default workspace    | 內建的共用瀏覽器，永遠都在；pinned tab 屬於它，在每個 workspace 都能使用                |
| 自訂 workspace       | 一個新的瀏覽器：每個網站都有自己的一份網站資料與登入                                    |
| Anonymous workspace  | 永遠排在最後；每個 tab 都是獨立的瀏覽器，隨 tab 關閉消失，只留 bookmark                 |
| Anonymous 外觀       | 身分不明的人像圖示；在其中時視窗轉為深炭黑、頁面維持系統外觀，網址列顯示 Anonymous 標記 |
| Workspace 顏色       | 在 workspace sheet 選八種顏色之一或不選；sidebar 與焦點框跟著上色                       |
| Sidebar 標題         | Default 和 Anonymous 在名稱下方附一行簡短說明；自訂 workspace 不顯示                    |
| 獨立的身分           | 登入、cookie 和網站資料各自保存在產生它們的 workspace 裡                                |
| 獨立的 fingerprint   | 每個 workspace 對每個網站都呈現一個不同且穩定的 fingerprint                             |
| 自己的瀏覽紀錄       | 每個瀏覽器保留造訪過的頁面，「顯示所有瀏覽紀錄」以 tab 列出；Anonymous 不留任何紀錄     |
| 一個頁面，一個瀏覽器 | 頁面始終屬於同一個瀏覽器；在另一個 workspace 開啟時，帶著網址過去重新開始               |
| 歸屬一目了然         | 每個頁面都顯示它屬於哪個瀏覽器                                                          |
| 資源用在當下         | 離開 workspace 時交還閒置頁面的資源；回來時只喚醒畫面上的那個頁面                       |
| 進行中的工作         | 未送出的文字、表單上傳、播放、相機或麥克風、全螢幕、popup 都讓頁面保持清醒              |
| 離開前詢問           | 會在離開前詢問的頁面也盡量保留；下載一定會完成                                          |
| 內容不外流           | 判斷頁面有未送出的工作時，不讀取欄位內容，也不把任何東西送出頁面                        |
| 輕盈好用             | 沒在用的 workspace 安靜無聲，切換快速，回來就能接著做                                   |
| 多個視窗             | ⌘N 再開一個共用同一組 workspace 的視窗；各自顯示自己的 tab，重開後還原                  |
| Lodge 頁面           | `lodge://settings` 與 `lodge://history` 以 tab 開啟，每個 workspace 各一個；網頁連不到  |
| 設定 tab             | ⌘, 或齒輪開啟：一般、搜尋、下載項目、關於（版本、macOS、資料夾）                        |
| 搜尋引擎             | 每個 workspace 用自己的搜尋引擎；在 workspace 選單的「搜尋引擎…」挑選                   |
| Default 的引擎       | 在「設定」的「搜尋」挑選；自訂 workspace 未自選前跟隨它；Anonymous 用 DuckDuckGo        |
| 自訂搜尋引擎         | 在「設定」的「搜尋」或「搜尋引擎…」sheet 按「加入搜尋引擎⋯」：名稱與 `…?q=%s` 網址      |
| 編輯與移除           | 每個加入的引擎在那裡都能編輯、移除；內建引擎維持不變                                    |
| 共用的引擎           | 在「設定」的「搜尋」加入的引擎，每個 workspace 都能選用，包括 Anonymous                 |
| 移除後               | 原本用它的改用：自訂 workspace 用 Default 的引擎，Default 和 Anonymous 用 DuckDuckGo    |
| 搜尋字詞             | 搜尋結果頁的網址列顯示搜尋字詞，前面附引擎圖示與名稱；改好按 Return 重新搜尋            |
| 拷貝位址             | 字詞未修改時，拷貝與「拷貝位址」仍給出頁面的完整網址                                    |
| 建議清單             | 在網址列或「打開位置」輸入時，下方列出搜尋、已開啟的 tab、bookmark 與瀏覽紀錄           |
| 只用本機資料         | 建議只來自目前 workspace 的 tab、bookmark 與瀏覽紀錄，從不連網                          |
| 選取建議             | ↑/↓ 在清單中移動，Return 開啟選取的項目，Esc 關閉清單                                   |
| 自動補完             | 欄位直接補上第一個建議；按 → 接受，刪除則捨棄補上的部分                                 |
| 預設瀏覽器           | 在「設定」tab 的「一般」設為預設；其他 app 的連結以新的 Default tab 開啟                |
| Credential           | 密碼和 passkey 來自 OS 的 credential store，在每個 workspace 都能使用                   |
| 英文與繁體中文       | 跟隨 macOS，或 Language & Region › Applications 裡 Lodge 的設定；workspace 名稱維持英文 |
| 三個平台             | Mac、iPhone、iPad 共用同一套規則，各自用最適合的方式操作                                |
| 清楚的承諾           | 每個 workspace 的網站資料與登入各自分開，Lodge 就照這樣說明                             |

## 為什麼不用現有的瀏覽器

| 能力                            | Lodge | Chrome / Edge | Firefox            | Safari      | Arc      |
| ------------------------------- | ----- | ------------- | ------------------ | ----------- | -------- |
| 一個視窗裡多個瀏覽器            | ✅    | ⚠️ profiles   | ⚠️ 只有 containers | ⚠️ profiles | ✅       |
| 每個 workspace 都有 Default pin | ✅    | ❌            | ❌                 | ❌          | ❌       |
| 整個 workspace 一起 hibernate   | ✅    | 只有 tab      | 只有 tab           | 只有 tab    | 只有 tab |
| iOS / iPadOS 同一套模型         | ✅    | ⚠️            | ❌                 | ✅          | ⚠️       |
| 系統層 credential               | ✅    | ⚠️            | ❌                 | ✅          | ❌       |

Lodge 以 WebKit 為底，passkey、service worker 和 extension 隨 Apple 對瀏覽器開放的能力而定。

## 發佈

`make publish` 用 fastlane 發佈 Lodge：一個 TestFlight build，以及經過公證的 Developer ID DMG；
有設 `GITHUB_REPOSITORY` 時，DMG 會發佈到 GitHub Release。

先設定一次：

1. 安裝 fastlane：`bundle install`。
2. 複製設定檔並填好：`cp .env.example .env`。每個 key 都列在 `.env.example` 裡並附有說明；
   shell 裡 export 的值優先於這個檔案。登入 App Store Connect 有兩種方式：
   - API key：設齊時一律使用，不會要求人操作。需要 `ASC_KEY_ID`、`ASC_ISSUER_ID`，以及放在
     `~/.appstoreconnect/private_keys/` 的 key 檔 `AuthKey_<ASC_KEY_ID>.p8`
     （也會找 `~/private_keys`、`~/.private_keys` 和 `./private_keys`），或把 `ASC_KEY_PATH` 設成它的路徑；
     相對的 `ASC_KEY_PATH` 從 repo 根目錄解析。`private_keys/` 和 `*.p8` 已被 git 忽略。
     平常執行（唯讀 match、profile、TestFlight 上傳）有 App Manager 角色就夠了。
   - Apple ID：沒有完整的 API key 時使用。需要 `APPLE_ID` 和 `FASTLANE_APPLE_APPLICATION_SPECIFIC_PASSWORD`
     （在 appleid.apple.com 產生的 app 專用密碼，只用於公證和 TestFlight 上傳）。查 build number、
     TestFlight 登入和 match 建立憑證則用 Apple ID 的帳號密碼登入：fastlane 第一次執行時會詢問一次，
     接著要求雙重認證，並把它存在 login keychain（項目 `deliver.<APPLE_ID>`），所以跑過 fastlane 的機器
     （即使是為了別的專案）不會再問。也可以用 `FASTLANE_PASSWORD` 提供，但建議留在 keychain。
     雙重認證大約每個月會再要求一次；session 快取在 `~/.fastlane/spaceship`。
   - GitHub Release 是選用的，在 `.env` 設 `GITHUB_REPOSITORY` 就會開啟，此時也必須設 `GITHUB_TOKEN`。
     只在 shell 裡 export `GITHUB_TOKEN` 不會開啟它。
3. `fastlane match` 使用 `MATCH_GIT_URL` 指定的團隊共用私有 repo（branch `main`，
   設定在 `fastlane/Matchfile`）；match 以 bundle ID 區分不同 app，所以不需要另建 repo。
   - `MATCH_PASSWORD` 不設或留空即可：在跑過 match 的機器上，match 會從 login keychain 讀取密語，
     只有沒有這筆 keychain 項目的機器才需要它。
   - 第一次執行要在 `.env` 設 `MATCH_READONLY=false`，讓 match 建立缺少的項目；之後再改回 `true`。
     共用 repo 很可能已經有 App Store 與 Mac installer 憑證，所以第一次執行主要是建立 Lodge 的 profile
     和 Developer ID 憑證。
   - 用 API key 建立憑證可能需要 Admin key，Developer ID 憑證則可能只有 Account Holder 能建立。
     用 Apple ID 時則依帳號角色而定：Account Holder 可以建立 Developer ID 憑證。
     若 match 建不了，就在 Xcode（Settings → Accounts → Manage Certificates）建立，匯出 `.p12`，再執行
     `bundle exec fastlane match import --type <type> --platform macos`，`<type>` 為 `appstore`、
     `mac_installer_distribution` 或 `developer_id` 其中之一。
4. 先在 App Store Connect 為 bundle ID（`APP_IDENTIFIER`）建立 app record；上傳前它必須已經存在。

接著發佈：

| 指令                 | 作用                                                                      |
| -------------------- | ------------------------------------------------------------------------- |
| `make publish-check` | 檢查 `.env`；列出缺少的 key，兩種登入方式都不完整時，列出各自缺少的項目   |
| `make publish`       | 執行 `make test` 和 `.env` 檢查，再跑 iOS/iPadOS lane 與下面的 macOS 發佈 |

`Lodge.xcodeproj` 還沒有對應 target 時，iOS 和 iPadOS lane 會略過。macOS lane（`mac publish`）：

1. 要求工作目錄乾淨且 `HEAD` 等於 `origin/main`：先 commit 並 push；
2. 把 Mac App Store pkg 上傳到 TestFlight；
3. 建置經過公證的 Developer ID DMG 到 `build/fastlane/`；有設 `GITHUB_REPOSITORY` 時，再發佈到 GitHub Release `v<version>`，
   沒設就略過 release，DMG 留在 `build/fastlane/`；
4. 在本機加上 tag `v<version>`，不會 push。

每次發佈前先調高 `MARKETING_VERSION`：tag `v<version>` 已經存在時，`mac publish` 會在建置前停下；
開啟 release 時，GitHub Release `v<version>` 已經存在也一樣。
失敗後重跑會用新的 build number。

把 `APP_IDENTIFIER` 從 `dev.lodge.Lodge` 改掉會讓 app 換一個新的 sandbox container，已保存的 session 不會帶過去。

## DDD (Dream-Driven Development)

這個專案遵循 DDD（dream-driven development）：每個功能都來自我的夢想和需要。
