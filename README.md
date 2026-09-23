# LabController

給 Apple 平台的 GitLab 事件控制器：一個相容 runner 協定的 CI 執行器，外加一層 MCP 控制面。

盯著一座 GitLab 站台，把倉庫上的動靜轉成結構化事件，在用完即丟的 Apple silicon 環境裡跑 CI job，並把狀態與事件經 MCP 攤給 LLM agent。

> 尚在初期——API 與範圍都還在調整。

## 需求

- Apple silicon，macOS 15 以上
- Swift 6 工具鏈；CI 以 Xcode 26.3 建置與測試
- 一座連得到的 GitLab 站台
- 聽在 Unix socket 上的 nymph，以及一份它每件 job 都複製得出來的基底

## 建置

```sh
swift build -c release
```

## 註冊 runner

`register` 拿 runner 的註冊 token 換一份認證 token，並把它印出來：

```sh
lab-controller register \
  --host https://gitlab.example.com \
  --registration-token <註冊 token> \
  --description "lab controller"
```

那份認證 token 只在這道指令的輸出裡出現，不寫進任何檔案，也不會再顯示第二次；請自己存到 `run` 讀得到的地方。

## 執行

```sh
lab-controller run \
  --host https://gitlab.example.com \
  --token-file /path/to/runner-token \
  --golden <基底別名> \
  --os mac
```

`run` 向站台領一件 job，在一台自基底複製出來的環境裡跑完，焚毀那台環境，然後再領下一件——直到收到停止訊號為止；給了 `--once` 就只處理一件。

認證 token 只從檔案讀、不開放旗標給：旗標會留在行程清單與 shell 歷史裡，而那把 token 等於站台交給這台 runner 的每一件 job。

| 選項 | 預設 | 作用 |
| --- | --- | --- |
| `--host` | 必填 | GitLab 站台的基底網址。 |
| `--token-file` | 必填 | 存著 runner 認證 token 的檔案。 |
| `--golden` | 必填 | 每件 job 各複製一份的基底別名。 |
| `--os` | 必填 | 要開哪一種環境：`mac` 或 `linux`。 |
| `--socket` | nymph 自己算出來的路徑 | nymph socket 的路徑。 |
| `--cpus` | `4` | 每台環境要幾顆 vCPU。 |
| `--memory-gib` | `4` | 每台環境要多少記憶體，單位 GiB。 |
| `--readiness-timeout` | `180` | 等一台剛開好的環境開始收命令的秒數。 |
| `--stop-grace` | `30` | 收到停止訊號之後，跑著的 job 還能再跑幾秒。 |
| `--once` | 關 | 處理完一件 job 就結束。 |
| `--log-level` | `info` | 紀錄門檻；未給時看 `LOG_LEVEL`。 |

## 紀錄

紀錄逐行寫到 stderr，一次一行——行程在緩衝區還沒送出去之前就被殺掉時，紀錄檔才留得下東西。門檻先看 `--log-level`，再看 `LOG_LEVEL`，兩者都沒有才是 `info`。`--log-level` 給了不是層級的值會跟其他旗標一樣被拒收；`LOG_LEVEL` 給了不是層級的值則提醒一次之後落回 `info`，環境變數打錯字不會讓命令起不來。

## 常駐在服務管理器底下

收到停止訊號時，已經在跑的那件 job 有 `--stop-grace` 秒可以自己跑完。寬限用完就焚毀它的環境、把這件 job 回報成環境層失敗——站台讀到的是可重試，會把它交給另一台 runner，而不是讓它一路跑到站台自己判它死掉。

服務管理器給的收工寬限要設得比 `--stop-grace` 長：launchd 預設 20 秒，而 `--stop-grace` 預設 30 秒，行程會在自己的寬限還沒用完時就被強殺，回寫送不出去，那段寬限也就白等了。

## 開發

```sh
swift build
swift test
```

格式化走 SwiftStyleKit 的 command plugin：

```sh
swift package plugin --allow-writing-to-package-directory format-source-code
```

風格檢查掛在各 target 的 SwiftStyleLint build tool plugin 上，`swift build` 時一併跑、以 warning 呈現；要讓 warning 升成 error，建置前設 `SWIFTSTYLELINT_STRICT=1`。

CI（`.github/workflows/ci.yml`）在每支 pull request 與推上 `main` 時跑 `swift build` 與 `swift test`，Xcode 釘在 26.3；另一支 `reuse.yml` 驗授權標頭合不合 REUSE 規範。
