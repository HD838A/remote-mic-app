# 豆包輸入法相容虛擬麥克風

MiRemoteV 2ch 是 Remote Mic 提供的獨立雙聲道迴環裝置，用於讓豆包能夠辨識遙控器語音。它可與 BlackHole 2ch 並存，不會修改、刪除或覆蓋 BlackHole。

## 安裝

不需要安裝 Xcode、Git，也不需要執行終端命令。

1. 在 DMG 根目錄雙擊 `Install SayAll.pkg`。
2. 在系統安裝器中按提示輸入管理員密碼。
3. 安裝器會同時安裝無線麥SayAll.app 和 MiRemoteV 2ch，重啟 CoreAudio，並自動啟動 SayAll。
4. 左鍵單擊選單欄圖示，在「連接與語音」中點選「重新整理音訊裝置」。
5. 點選「選擇 MiRemoteV 2ch」。
6. 完全退出並重新開啟豆包後再次測試。

## 驗證

在 QuickTime Player 中選擇「檔案 → 新建音訊錄製」，把輸入裝置設為 MiRemoteV 2ch。按住遙控器語音鍵說話時，輸入電平應發生變化。

如果 QuickTime 有電平但豆包沒有反應，請重新單擊可編輯輸入框，確認插入游標已經出現，再按住語音鍵。

## 解除安裝

從同一 Release 下載並雙擊 `SayAll-<版本>-Uninstaller.pkg`。它會校驗並將無線麥SayAll.app、已辨識的歷史 App 與 MiRemoteV 2ch 移到 macOS 廢紙簍，然後重啟 CoreAudio；不會修改 BlackHole 或無線麥的本地設定。

## 技術與許可

該驅動由固定的 BlackHole v0.7.1 原始碼、專案補丁和釋出構建引數生成。實際 Audio Device 報告為 USB transport，裝置名為 MiRemoteV 2ch。

BlackHole 採用 GPL-3.0 許可。詳情見應用包內的 THIRD_PARTY_NOTICES.md。
