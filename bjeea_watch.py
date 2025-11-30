#!/usr/bin/env python3
"""
BJEEA page watcher

- 監控：
  * https://www.bjeea.cn/html/hk/index.html   （高中学考合格考）
  * https://www.bjeea.cn/html/gkgz/index.html （高考高招）

- 把兩個欄目的新文章，按時間順序追加成回覆，發到同一個 Discourse 主題。

配置使用環境變量（可由 systemd EnvironmentFile 注入）：
  DISCOURSE_BASE_URL
  DISCOURSE_API_KEY
  DISCOURSE_API_USERNAME
  BJEEA_TOPIC_ID

可選：
  BJEEA_LOG_LEVEL       （默認 INFO）
  BJEEA_STATE_PATH      （默認 /var/lib/bjeea-watch/state.json）
"""

from __future__ import annotations

import json
import logging
import os
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Dict, List, Tuple

import requests
from bs4 import BeautifulSoup

VERSION = "1.3.2"

LOGGER_NAME = "bjeea_watch"
logger = logging.getLogger(LOGGER_NAME)


@dataclass
class SectionConfig:
    key: str
    index_url: str
    source_page_name: str   # 「來源頁面」欄位
    footer_label: str       # footer 顯示用


SECTIONS: Dict[str, SectionConfig] = {
    "hk": SectionConfig(
        key="hk",
        index_url="https://www.bjeea.cn/html/hk/index.html",
        source_page_name="高中学考合格考",
        footer_label="高中学考合格考",
    ),
    "gkgz": SectionConfig(
        key="gkgz",
        index_url="https://www.bjeea.cn/html/gkgz/index.html",
        source_page_name="高考高招",
        footer_label="高考高招",
    ),
}

STATE_DEFAULT = {
    "hk": {"seen_urls": []},
    "gkgz": {"seen_urls": []},
}


# ───────────────────────── logging ───────────────────────── #

def setup_logging() -> None:
    level_name = os.getenv("BJEEA_LOG_LEVEL", "INFO").upper()
    level = getattr(logging, level_name, logging.INFO)

    handler = logging.StreamHandler(sys.stdout)
    fmt = "%(asctime)s [%(levelname)s] %(name)s: %(message)s"
    handler.setFormatter(logging.Formatter(fmt))

    root = logging.getLogger()
    root.setLevel(level)
    root.handlers.clear()
    root.addHandler(handler)


# ───────────────────────── state I/O ─────────────────────── #

def get_state_path() -> str:
    return os.getenv("BJEEA_STATE_PATH", "/var/lib/bjeea-watch/state.json")


def load_state(path: str) -> Dict:
    if not os.path.exists(path):
        logger.info("State file %s does not exist, using default.", path)
        return json.loads(json.dumps(STATE_DEFAULT))

    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except Exception as e:
        logger.warning("Failed to load state file %s: %s, using empty default.", path, e)
        return json.loads(json.dumps(STATE_DEFAULT))

    # 確保 key 存在
    for key in STATE_DEFAULT:
        data.setdefault(key, {})
        data[key].setdefault("seen_urls", [])
    return data


def save_state(path: str, state: Dict) -> None:
    tmp_path = f"{path}.tmp"
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(tmp_path, "w", encoding="utf-8") as f:
        json.dump(state, f, ensure_ascii=False, indent=2)
    os.replace(tmp_path, path)
    logger.info("State saved to %s", path)


# ───────────────────────── HTTP helpers ──────────────────── #

def build_session() -> requests.Session:
    s = requests.Session()
    s.headers.update({
        "User-Agent": f"bjeea-watch/{VERSION} (+https://forum.rdfzer.com/)",
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    })
    return s


def fetch_html(session: requests.Session, url: str) -> BeautifulSoup:
    """
    統一入口：
    - 用 resp.content（bytes）交給 BeautifulSoup，讓它根據 <meta charset> 自己判斷。
    - 不再動 resp.text / 手動編碼，避免亂碼。
    """
    logger.info("Fetching %s", url)
    resp = session.get(url, timeout=30)
    resp.raise_for_status()
    # 關鍵：用 .content，而不是 .text
    return BeautifulSoup(resp.content, "html.parser")


# === 向後兼容：老腳本 free_one_from_index / free_one_url 依賴的函數名 === #

def fetch_page(session: requests.Session, url: str) -> BeautifulSoup:
    """
    Backward-compatible wrapper for old code.

    free_one_from_index.py / free_one_url.py 早期是從這裡 import fetch_page；
    現在統一轉到新版 fetch_html。
    """
    return fetch_html(session, url)


# ───────────────────────── index parsing ─────────────────── #

def extract_article_links(soup: BeautifulSoup, section: SectionConfig) -> List[str]:
    """
    從欄目首頁提取文章 URL：

    規則：
      - href 含有 /html/{section.key}/
      - 以 .html 結尾
      - 排除 index.html
    按在頁面中出現順序去重。
    """
    links: List[str] = []
    prefix = f"/html/{section.key}/"

    for a in soup.find_all("a", href=True):
        href = a["href"].strip()
        if not href:
            continue
        if not href.endswith(".html"):
            continue
        if prefix not in href:
            continue
        if href.endswith("index.html"):
            continue

        if href.startswith("http://") or href.startswith("https://"):
            full_url = href
        else:
            full_url = requests.compat.urljoin(section.index_url, href)

        if full_url not in links:
            links.append(full_url)

    return links


def extract_items(soup: BeautifulSoup, section: SectionConfig) -> List[str]:
    """
    Backward-compatible wrapper: 老版本叫 extract_items，現在轉到 extract_article_links。
    """
    return extract_article_links(soup, section)


# ───────────────────────── article parsing ───────────────── #

def extract_text_from_content_node(node) -> str:
    """
    從正文容器裡抽取純文字，保留段落，去掉多餘空白。
    """
    paragraphs: List[str] = []

    # 優先 p / li
    for p in node.find_all(["p", "li"]):
        text = p.get_text(separator="", strip=True)
        if text:
            paragraphs.append(text)

    # 如果沒拿到任何段落，退而求其次整塊文本
    if not paragraphs:
        raw = node.get_text(separator="\n", strip=True)
        lines = [line.strip() for line in raw.splitlines() if line.strip()]
        return "\n\n".join(lines)

    return "\n\n".join(paragraphs)


def parse_article(session: requests.Session, url: str) -> Dict[str, str]:
    """
    解析文章頁面：
      - title: info-ctit
      - date: info-times 裡第一個 span
      - body: info-txt / inner20 裡的段落
    全程只操作 Unicode 字串，不做 encode/decode 花活。
    """
    soup = fetch_html(session, url)

    # 標題
    title_div = soup.find("div", class_="info-ctit")
    if title_div is None:
        title = ""
    else:
        title = title_div.get_text(strip=True)

    # 日期
    date_div = soup.find("div", class_="info-times")
    date_text = ""
    if date_div is not None:
        span = date_div.find("span")
        if span is not None:
            date_text = span.get_text(strip=True)

    # 正文
    body_node = None
    info_txt = soup.find("div", class_="info-txt")
    if info_txt is not None:
        inner = info_txt.find("div", class_="inner20")
        body_node = inner or info_txt

    body_text = ""
    if body_node is not None:
        body_text = extract_text_from_content_node(body_node)

    return {
        "title": title or "",
        "date": date_text or "",
        "body": body_text or "",
    }


# ───────────────────────── Discourse posting ─────────────── #

def get_discourse_config() -> Tuple[str, str, str, int]:
    base_url = os.environ.get("DISCOURSE_BASE_URL")
    api_key = os.environ.get("DISCOURSE_API_KEY")
    api_username = os.environ.get("DISCOURSE_API_USERNAME")
    topic_id_raw = os.environ.get("BJEEA_TOPIC_ID")

    missing = [name for name, val in [
        ("DISCOURSE_BASE_URL", base_url),
        ("DISCOURSE_API_KEY", api_key),
        ("DISCOURSE_API_USERNAME", api_username),
        ("BJEEA_TOPIC_ID", topic_id_raw),
    ] if not val]

    if missing:
        raise SystemExit(f"Missing required environment variables: {', '.join(missing)}")

    try:
        topic_id = int(topic_id_raw)  # type: ignore[arg-type]
    except ValueError:
        raise SystemExit(f"BJEEA_TOPIC_ID must be integer, got {topic_id_raw!r}")

    return base_url.rstrip("/"), api_key, api_username, topic_id


def build_post_body(section: SectionConfig, article_url: str, meta: Dict[str, str]) -> str:
    title = (meta.get("title") or "").strip() or article_url
    date_text = (meta.get("date") or "").strip() or "（未找到日期）"
    body_text = (meta.get("body") or "").rstrip() or "（未能解析正文）"

    grabbed_at = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S %Z")
    site_name = "北京教育考试院"

    lines: List[str] = []
    lines.append("新公告")
    lines.append(f"原文標題：{title}")
    lines.append(f"原文日期：{date_text}")
    lines.append(f"原文鏈接：{article_url}")
    lines.append("")
    lines.append(f"來源頁面：{section.source_page_name}")
    lines.append(f"來源站點：{site_name}")
    lines.append(f"抓取時間：{grabbed_at}")
    lines.append("")
    lines.append("正文：")
    lines.append(body_text)
    lines.append("")
    lines.append(f"—— 自動監控腳本轉發（{section.footer_label}）")

    return "\n".join(lines)


def post_to_discourse(raw: str) -> None:
    base_url, api_key, api_username, topic_id = get_discourse_config()

    url = f"{base_url}/posts.json"
    payload = {
        "topic_id": topic_id,
        "raw": raw,
    }
    headers = {
        "Api-Key": api_key,
        "Api-Username": api_username,
    }

    resp = requests.post(url, json=payload, headers=headers, timeout=30)
    try:
        resp.raise_for_status()
    except Exception as e:
        logger.error("Failed to post to Discourse (HTTP %s): %s, response=%r",
                     resp.status_code, e, resp.text[:500])
        raise

    logger.info("Created reply in topic_id=%s (status=%s)", topic_id, resp.status_code)


# ───────────────────────── main logic ────────────────────── #

def handle_section(
    session: requests.Session,
    section: SectionConfig,
    state: Dict,
) -> None:
    section_state = state.setdefault(section.key, {}).setdefault("seen_urls", [])
    if not isinstance(section_state, list):
        section_state = []
        state[section.key]["seen_urls"] = section_state

    logger.info("Handling section %s (%s)", section.key, section.index_url)
    soup = fetch_html(session, section.index_url)
    links = extract_article_links(soup, section)
    logger.info("Extracted %d article links from %s", len(links), section.index_url)

    seen_urls: List[str] = section_state  # alias
    new_urls = [u for u in links if u not in seen_urls]

    if not new_urls:
        logger.info("No new items for section %s.", section.key)
        return

    _, _, _, topic_id = get_discourse_config()
    logger.info(
        "Found %d new items for section %s, will append to topic_id=%s.",
        len(new_urls), section.key, topic_id,
    )

    for article_url in new_urls:
        logger.info("Fetching article: %s", article_url)
        meta = parse_article(session, article_url)
        raw = build_post_body(section, article_url, meta)
        logger.info("Posting reply to Discourse topic_id=%s", topic_id)
        post_to_discourse(raw)

        seen_urls.append(article_url)

    # 每個 section 處理完就保存一次保險
    save_state(get_state_path(), state)


def main() -> None:
    setup_logging()
    logger.info("bjeea_watch.py starting (version %s)", VERSION)

    state_path = get_state_path()
    state = load_state(state_path)

    session = build_session()

    # 順序固定：hk -> gkgz
    for key in ("hk", "gkgz"):
        section = SECTIONS[key]
        handle_section(session, section, state)

    logger.info("bjeea_watch.py finished.")


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception as e:
        # 確保任何未捕獲的異常也打 log
        logger.exception("Unhandled exception: %s", e)
        raise
