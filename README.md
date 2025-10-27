 # 1、教科書

> 需要語文，順便下載 K12 全部教科書，嗯。   
其實是在構想一個更大教科書項目。  

 ```bash
bash <(curl -Ls https://raw.githubusercontent.com/ieduer/bdfz/main/jks.sh)
```

 
 
 # 2、SAA

> 基於 <a href="https://github.com/c-jeremy/sue/blob/main/pseudo-auth.php" target="_blank" rel="noopener noreferrer">pseudo-auth.php</a> ，通過最小抓包實現；提供 API 化版本。**該版本無視時間限制**；此倉庫附帶「暴力」舊版供研究與自用。

---


```bash
bash <(curl -Ls https://raw.githubusercontent.com/ieduer/bdfz/main/saa.sh)
```

---

## 背景與記錄

- 最不值：<a href="https://bdfz.net/posts/imgseiue/" target="_blank" rel="noopener noreferrer">noatt</a>
- 點不點名：<a href="https://bdfz.net/posts/attendance/" target="_blank" rel="noopener noreferrer">attendance</a>

> 無意義之事，以無意義待之；技術的價值，大概也在於此。

---

# 3、IP Menu

> A tiny macOS **menubar** utility that shows your public IP (with country + ASN/ISP) and reacts quickly to VPN/proxy node changes (e.g., **sing-box**). Runs without a Dock icon and auto-starts via LaunchAgent. Single-file installer.

- **Menubar-only** (no Dock icon), built with `rumps` + `pyobjc`
- **Public IP** with fast refresh; falls back to local IP
- **ASN/ISP** via online (ipinfo/ip-api) or offline (sapics ip-location-db)
- **Country** display: off / **code** / name
- **IPv4 formatting**: full / first 2 / first + last / last 2
- **Change notifications** for public/local IP; optional sound
- **LaunchAgent** autostart; one-click **Reload** from the menu


```bash
bash <(curl -Ls https://raw.githubusercontent.com/ieduer/bdfz/main/ipmenu.sh)
```

# 4、Vps

> 需要十幾台機子的實時情況的隨時 Tele 消息，所以寫了。  

```bash
<(curl -Ls https://raw.githubusercontent.com/ieduer/bdfz/main/vps.sh)
```

# 5、WX2HTML 

微信不公號：<a href="https://bdfz.net/posts/fuckwechat/" target="_blank" rel="noopener noreferrer">那麼，我搬。</a>

# 6、臺灣華文電子書庫

> 偶爾需要下載庫內書，寫下。  

```bash
<(curl -Ls https://raw.githubusercontent.com/ieduer/bdfz/main/taiwanebook.sh)
```

---

# 免責聲明

- 皆為個人項目，僅供學術研究與個人學習之用，請勿用於任何違規行為。
- 使用產生的風險由使用者自行承擔。
- 直接都考了，不太好吧。😜