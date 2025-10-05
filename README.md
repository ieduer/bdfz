 # SAA

> 基於 <a href="https://github.com/c-jeremy/sue/blob/main/pseudo-auth.php" target="_blank" rel="noopener noreferrer">pseudo-auth.php</a> ，通過最小抓包實現；提供 API 化版本。**該版本無視時間限制**；此倉庫附帶「暴力」舊版供研究與自用。



---

## macOS / Homebrew

```bash
bash <(curl -Ls https://raw.githubusercontent.com/ieduer/bdfz/main/saa.sh)
# 或
bash <(wget -qO- https://raw.githubusercontent.com/ieduer/bdfz/main/saa.sh)
```

> 若 `curl` / `wget` 均不可用，請手動下載 `saa.sh` 後執行：`bash saa.sh`。

---


## 背景與記錄

- 最不值：<a href="https://bdfz.net/posts/imgseiue/" target="_blank" rel="noopener noreferrer">noatt</a>
- 點不點名：<a href="https://bdfz.net/posts/attendance/" target="_blank" rel="noopener noreferrer">attendance</a>

> 無意義之事，以無意義待之；技術的價值，大概也在於此。

---

## 免責聲明

- 本項目僅供學術研究與個人學習之用，請勿用於任何違規行為。
- 使用產生的風險由使用者自行承擔。
- 直接都考了，不太好吧。😜

---

# IP Menu

A tiny macOS **menubar** utility that shows your public IP (with country + ASN/ISP) and reacts quickly to VPN/proxy node changes (e.g., **sing-box**). Runs without a Dock icon and auto-starts via LaunchAgent. Single-file installer.

- **Menubar-only** (no Dock icon), built with `rumps` + `pyobjc`
- **Public IP** with fast refresh; falls back to local IP
- **ASN/ISP** via online (ipinfo/ip-api) or offline (sapics ip-location-db)
- **Country** display: off / **code** / name
- **IPv4 formatting**: full / first 2 / first + last / last 2
- **Change notifications** for public/local IP; optional sound
- **LaunchAgent** autostart; one-click **Reload** from the menu

---

## Install (one-liner)

```bash
bash <(curl -Ls https://raw.githubusercontent.com/ieduer/bdfz/main/ipmenu.sh)
# 或
bash <(wget -qO- https://raw.githubusercontent.com/ieduer/bdfz/main/ipmenu.sh)
```