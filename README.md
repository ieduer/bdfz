# BDFZ 工具合集

日常教學、運維、折騰腳本們。

⸻

## 目錄

1. 教科書（JKS）
2. SAA：Seiue 考勤
3. IP Menu：macOS 公網 IP 菜單欄
4. VPS：多機狀態 → Telegram
5. WX2HTML：微信圖文搬運
6. 臺灣華文電子書庫下載
7. Seiue Notification → Telegram
8. SeiueStu → Telegram
9. Mentee：導師約談記錄
10. YDW：臨時文件下載
11. yue-auto-mark：K12media AI 閱卷
12. quiz-submit：年度考核自動提交
13. k12media_download_imgs：閱卷原卷圖下載

⸻

## 1. 教科書（JKS）

需要語文，順便下載 K12 全部教科書。其實是在構想一個更大的教科書項目。

一鍵拉取並整理指定年級 / 科目的教科書資源，方便本地索引和後續處理（例如送進 NotebookLM、RAG 等）。

```bash
bash <(curl -Ls https://raw.githubusercontent.com/ieduer/bdfz/main/jks.sh)
```

⸻

## 2. SAA：Seiue 考勤

考勤，無視時間限制。

```bash
bash <(curl -Ls https://raw.githubusercontent.com/ieduer/bdfz/main/saa.sh)
```

背景與記錄

- 最不值：https://bdfz.net/posts/imgseiue/
- 點不點名：https://bdfz.net/posts/attendance/

無意義之事，以無意義待之；技術的價值，大概也在於此。

⸻

## 3. IP Menu：macOS 公網 IP 菜單欄

A tiny macOS menubar utility that shows your public IP (with country + ASN/ISP) and reacts quickly to VPN/proxy node changes.

特性：

- 僅菜單欄圖示，無 Dock 圖標
- 顯示公網 IP，快速刷新；失敗時回退本地 IP
- 顯示 ASN / ISP、國家（可選關閉 / 顯示國碼 / 顯示國名）
- IPv4 顯示方式：完整 / 前兩段 / 首尾 / 後兩段
- 公網 / 本地 IP 變化時可通知（可選聲音）
- 自動寫入 LaunchAgent，開機自動啟動
- 菜單內一鍵 Reload 配置

安裝：

```bash
bash <(curl -Ls https://raw.githubusercontent.com/ieduer/bdfz/main/ipmenu.sh)
```


⸻

## 4. VPS：多機狀態 → Telegram

需要十幾台機子的實時情況，隨時 Tele 消息，所以寫了。

定時拉取多台 VPS 的 CPU / RAM / load / 磁碟 等信息，匯總推 Telegram。

```bash
bash <(curl -Ls https://raw.githubusercontent.com/ieduer/bdfz/main/vps.sh)
```


⸻

## 5. WX2HTML：微信圖文搬運

微信不公號： 那麼，我搬。￼

將微信文章提取為乾淨的 HTML / Markdown，用於博客備份或教學資料整理。

⸻

## 6. 臺灣華文電子書庫下載

偶爾需要下載庫內書，用於從「臺灣華文電子書庫」按書號 / 搜索結果批量下載電子書，便於本地閱讀與備份。

```bash
bash <(curl -Ls https://raw.githubusercontent.com/ieduer/bdfz/main/taiwanebook.sh)
```


⸻

## 7. Seiue Notification → Telegram

網頁的通知算通知嗎？當然 TM 不算。所以，推過來吧。

監聽 Seiue 通知（系統通知 / 請假 / 任務等），拉到本地後轉發至 Telegram Bot。

```bash
bash <(curl -Ls https://raw.githubusercontent.com/ieduer/bdfz/main/seiue-notify.sh)
```


⸻

## 8. SeiueStu → Telegram

一個個了解。同步 Seiue 學生名單與基本信息：

可以用來快速查詢學生、綁定備註、或作為後續自動化（考勤、成績通知）的基礎數據層。

```bash
bash <(curl -Ls https://raw.githubusercontent.com/ieduer/bdfz/main/seiuestu.sh)
```


⸻

## 9. Mentee：導師約談記錄

導導導，但不是寫這玩意。給導生/學生建個「側寫檔案」的工具：支持從命令行快速記錄備註、標籤、關鍵事件，便於導師工作時回顧與整理。

```bash
bash <(curl -Ls https://raw.githubusercontent.com/ieduer/bdfz/main/mentee.sh)
```


⸻

## 10. YDW：臨時文件下載

偶爾救急。輕量下載/中轉小工具，適合臨時拉取大文件、轉存到指定 VPS 或雲端存儲，避免在本機/教學機器上折騰。

```bash
bash <(curl -Ls https://raw.githubusercontent.com/ieduer/bdfz/main/dl.sh)
```


⸻

## 11.yue-auto-mark：K12media AI 閱卷

K12media AI 閱卷。

針對 yue.k12media.cn 閱卷系統的自動評卷腳本：

- 自動登入與 token 續期
- 連續拉取待批試卷、下載原卷圖片
- 調用 AI（OCR + 評分 + 簡短評語）
- 根據預設 rubric 自動打分並提交
- 統計已批份數、錯誤數、重試等

```bash
bash <(curl -Ls https://raw.githubusercontent.com/ieduer/bdfz/main/yue-auto-mark.sh)
```


⸻

## 12. quiz-submit：年度考核自動提交

前世冤。年度考核 AI 化。

面向年度考核 / 線上測評網站的自動提交腳本：

- 按既定答案/模板生成作答內容
- 支援從剪貼板讀取 QUIZ_ID（方便瀏覽器複製粘貼）
- 自動探測版本號（XVER）以兼容前端更新
- 結合 Seiue 登錄模式與 quiz 自身的 SSO 流程

```bash
bash <(curl -Ls https://raw.githubusercontent.com/ieduer/bdfz/main/quiz-submit.sh)
```


⸻

## 13. k12media_download_imgs：閱卷原卷圖下載

有圖有手寫。

對 K12media 閱卷系統成績報表進行解析，批量下載對應的學生試卷原圖，便於：

- 建立本地「錯題本」圖庫
- 製作 NotebookLM / RAG 教學資料
- 統計書寫特徵、分析題目質量等

⸻