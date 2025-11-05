#!/usr/bin/env bash
# Seiue Chat Autofill from Tutor Group - installer/runner
# v0.4.8-sh-2025-11-05

set -euo pipefail

APP_DIR="/opt/mentee"
PY_ENV="$APP_DIR/venv"
PY_MAIN="$APP_DIR/mentee.py"
VERSION="v0.4.8-sh-2025-11-05"

echo "[mentee] installer version: $VERSION"

have() { command -v "$1" >/dev/null 2>&1; }

# 先殺掉舊的進程（你說每次都要覆蓋重裝殺掉舊進程）
kill_old() {
  echo "[mentee] killing old processes (if any)..."
  # 精準殺我們這條
  pkill -f "$PY_MAIN" 2>/dev/null || true
  # 保險殺一下名字
  pkill -f mentee.py 2>/dev/null || true
}

detect_os() {
  if [ -f /etc/alpine-release ]; then
    echo "alpine"
  elif [ -f /etc/debian_version ] || [ -f /etc/lsb-release ]; then
    echo "debian"
  elif [ -f /etc/redhat-release ]; then
    echo "redhat"
  else
    echo "unknown"
  fi
}

install_deps() {
  local os="$1"
  echo "[mentee] detecting OS: $os"
  case "$os" in
    debian)
      sudo apt-get update -y
      sudo apt-get install -y python3 python3-venv python3-pip curl git
      ;;
    redhat)
      sudo yum install -y python3 python3-pip curl git ||
      sudo dnf install -y python3 python3-pip curl git
      ;;
    alpine)
      sudo apk add --no-cache python3 py3-pip curl git
      ;;
    *)
      echo "[mentee] unknown OS, assuming python3/pip already present."
      ;;
  esac
}

prepare_env() {
  sudo rm -rf "$APP_DIR"
  sudo mkdir -p "$APP_DIR"
  sudo chown "$(id -u):$(id -g)" "$APP_DIR"

  if [ ! -d "$PY_ENV" ]; then
    echo "[mentee] creating venv at $PY_ENV"
    python3 -m venv "$PY_ENV"
  fi
  # shellcheck disable=SC1091
  . "$PY_ENV/bin/activate"
  pip install --upgrade pip >/dev/null
  pip install requests >/dev/null
}

write_python() {
  cat >"$PY_MAIN" <<'PY'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Seiue Chat Autofill from Tutor Group
v0.4.8-2025-11-05 (VPS shell edition)

特性：
- 支援從 .seiue.env / ~/.seiue.env 讀取你貼進去的 Bearer、reflection_id
- 照你抓包：先看 chat.custom_fields.form_id，沒有才退回模板 13907
- 送答案的 URL 用模板 id，不寫死實例 id
- 支援附件
"""

import os
import sys
import json
import time
import datetime
from typing import List, Optional

try:
    import requests  # noqa
except ImportError:
    print("[autofill] requests not installed, please run installer.", file=sys.stderr)
    sys.exit(1)

# ====== 嘗試跳到你本機那個 venv（如果 VPS 偶然也有就會用）======
_venv_py = os.path.expanduser("~/.venvs/ingest/bin/python")
if os.path.exists(_venv_py) and sys.executable != _venv_py:
    os.execv(_venv_py, [_venv_py] + sys.argv)

def load_dotenv_if_exists(path: str) -> None:
    if not os.path.exists(path):
        return
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            k = k.strip()
            v = v.strip().strip('"').strip("'")
            os.environ[k] = v

# 優先當前目錄
load_dotenv_if_exists(os.path.join(os.getcwd(), ".seiue.env"))
# 再讀家目錄
load_dotenv_if_exists(os.path.expanduser("~/.seiue.env"))

SEIUE_BASE = os.getenv("SEIUE_BASE", "https://api.seiue.com")
SEIUE_BEARER_RAW = os.getenv("SEIUE_BEARER", "").strip()
SEIUE_SCHOOL_ID = os.getenv("SEIUE_SCHOOL_ID", "3")
SEIUE_ROLE = os.getenv("SEIUE_ROLE", "teacher")
TEACHER_REFLECTION_ID = os.getenv("SEIUE_REFLECTION_ID", "")
GROUP_ID = os.getenv("SEIUE_GROUP_ID", "2192044")
CLASS_ID = os.getenv("SEIUE_CLASS_ID", "1815547")
CHAT_INSTANCE_ID = int(os.getenv("SEIUE_CHAT_INSTANCE_ID", "7"))
CHAT_FORM_TEMPLATE_ID = int(os.getenv("SEIUE_CHAT_FORM_TEMPLATE_ID", "13907"))
DRY_RUN = os.getenv("DRY_RUN", "0") == "1"

FIELD_TEACHER_RECORD = int(os.getenv("SEIUE_FIELD_TEACHER_RECORD", "279912"))
FIELD_TEACHER_ATTACHMENT = int(os.getenv("SEIUE_FIELD_TEACHER_ATTACHMENT", "280000"))
DEFAULT_RECORD_TEXT = os.getenv(
    "SEIUE_DEFAULT_RECORD_TEXT",
    "本次約談已補錄，內容請以校內系統為準。"
)

_seiue_photo_name = os.getenv("SEIUE_PHOTO_NAME")
_seiue_photo_hash = os.getenv("SEIUE_PHOTO_HASH")
_seiue_photo_size = os.getenv("SEIUE_PHOTO_SIZE")
_seiue_photo_mime = os.getenv("SEIUE_PHOTO_MIME", "image/jpeg")
if _seiue_photo_name and _seiue_photo_hash and _seiue_photo_size:
    DEFAULT_ATTACHMENT = {
        "name": _seiue_photo_name,
        "size": int(_seiue_photo_size),
        "hash": _seiue_photo_hash,
        "mime": _seiue_photo_mime,
    }
else:
    DEFAULT_ATTACHMENT = None


def normalize_bearer(token: str) -> str:
    if not token:
        return ""
    t = token.strip()
    if t.lower().startswith("bearer "):
        t = t[7:].strip()
    return t


def debug(msg: str):
    print(f"[autofill] {msg}")


def make_session() -> "requests.Session":
    token = normalize_bearer(SEIUE_BEARER_RAW)
    print("[autofill] USING BEARER:", SEIUE_BEARER_RAW[:80], "...")
    print("[autofill] USING REFLECTION:", TEACHER_REFLECTION_ID)
    if not token or not TEACHER_REFLECTION_ID:
        raise SystemExit("請先設置 SEIUE_BEARER 和 SEIUE_REFLECTION_ID")
    s = requests.Session()
    s.headers.update({
        "Host": "api.seiue.com",
        "authorization": f"Bearer {token}",
        "sec-ch-ua-platform": "\"macOS\"",
        "sec-ch-ua": "\"Chromium\";v=\"142\", \"Brave\";v=\"142\", \"Not_A Brand\";v=\"99\"",
        "x-reflection-id": TEACHER_REFLECTION_ID,
        "sec-ch-ua-mobile": "?0",
        "x-school-id": SEIUE_SCHOOL_ID,
        "x-role": SEIUE_ROLE,
        "user-agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Safari/537.36",
        "accept": "application/json, text/plain, */*",
        "sec-gpc": "1",
        "origin": "https://chalk-c3.seiue.com",
        "sec-fetch-site": "same-site",
        "sec-fetch-mode": "cors",
        "sec-fetch-dest": "empty",
        "referer": "https://chalk-c3.seiue.com/",
        "accept-language": "en-US,en;q=0.9,zh-CN;q=0.8,zh-TW;q=0.7,zh;q=0.6",
        "priority": "u=1, i",
    })
    return s


def fetch_group_students(s: "requests.Session", group_id: str, class_id: str) -> list[int]:
    url = f"{SEIUE_BASE}/chalk/group/groups/{group_id}/members"
    params = {
        "class_id": class_id,
        "expand": "teams,group,reflection,team",
        "paginated": "0",
        "sort": "member_type_id,-top,reflection.usin",
    }
    debug(f"fetch group members → {url} {params}")
    resp = s.get(url, params=params, timeout=15)
    if not resp.ok:
      debug(f"HTTP {resp.status_code} when fetching group members: {resp.text}")
      resp.raise_for_status()
    data = resp.json()
    students: list[int] = []
    for m in data:
        if m.get("member_type") == "student" and m.get("status") == "normal":
            rid = m.get("member_id")
            if rid:
                students.append(int(rid))
    return students


def iso_now_offset(minutes: int = 0) -> str:
    dt = datetime.datetime.utcnow() + datetime.timedelta(minutes=minutes)
    return dt.strftime("%Y-%m-%d %H:%M:%S")


def create_chat(s: "requests.Session", student_rid: int) -> int:
    start_time = iso_now_offset(-5)
    end_time = (datetime.datetime.strptime(start_time, "%Y-%m-%d %H:%M:%S")
                + datetime.timedelta(minutes=10)).strftime("%Y-%m-%d %H:%M:%S")
    payload = {
        "title": "約談補錄",
        "content": "系統自動補錄的約談記錄。",
        "attachments": [],
        "member_ids": [int(TEACHER_REFLECTION_ID), int(student_rid)],
        "place_name": "辦公室",
        "start_time": start_time,
        "end_time": end_time,
        "custom_fields": {
            "chat_method": "offline",
            "is_classin": False,
            "chat_type": "chat",
        },
    }
    url = f"{SEIUE_BASE}/chalk/chat/instances/{CHAT_INSTANCE_ID}/chats"
    debug(f"create chat → student {student_rid}")
    if DRY_RUN:
        debug(f"DRY_RUN create payload: {json.dumps(payload, ensure_ascii=False)}")
        return 0
    resp = s.post(url, json=payload, timeout=15)
    if not resp.ok:
        debug(f"HTTP {resp.status_code} on create_chat: {resp.text}")
        resp.raise_for_status()
    return int(resp.json()["id"])


def _extract_form_id_from_chat(data: dict) -> Optional[int]:
    if not isinstance(data, dict):
        return None
    cf = data.get("custom_fields") or {}
    if isinstance(cf, dict) and cf.get("form_id"):
        return int(cf["form_id"])
    if isinstance(data.get("chat_form"), dict) and "id" in data["chat_form"]:
        return int(data["chat_form"]["id"])
    if isinstance(data.get("form"), dict) and "id" in data["form"]:
        return int(data["form"]["id"])
    if isinstance(data.get("forms"), list) and data["forms"]:
        first = data["forms"][0]
        if isinstance(first, dict) and "id" in first:
            return int(first["id"])
    return None


def fetch_chat_form_instance_id(s: "requests.Session", chat_id: int) -> int:
    base_url = f"{SEIUE_BASE}/chalk/chat/instances/{CHAT_INSTANCE_ID}/chats/{chat_id}"
    try:
        resp = s.get(base_url, params={"expand": "chat_form,form,forms"}, timeout=15)
        if resp.ok:
            data = resp.json()
            debug(f"chat raw (expand): {json.dumps(data, ensure_ascii=False)}")
            form_id = _extract_form_id_from_chat(data)
            if form_id:
                return form_id
        else:
            debug(f"expand not ok: {resp.status_code} {resp.text}")
    except Exception as e:
        debug(f"expand exploded: {e}")

    try:
        resp = s.get(base_url, timeout=15)
        if resp.ok:
            data = resp.json()
            debug(f"chat raw (plain): {json.dumps(data, ensure_ascii=False)}")
            form_id = _extract_form_id_from_chat(data)
            if form_id:
                return form_id
        else:
            debug(f"plain not ok: {resp.status_code} {resp.text}")
    except Exception as e:
        debug(f"plain exploded: {e}")

    debug(f"fallback to template {CHAT_FORM_TEMPLATE_ID}")
    return CHAT_FORM_TEMPLATE_ID


def submit_chat_form(s: "requests.Session", chat_id: int, record_text: str, instance_form_id: int):
    answers = [
        {
            "label": record_text,
            "form_id": instance_form_id,
            "form_template_field_id": FIELD_TEACHER_RECORD,
        }
    ]
    if DEFAULT_ATTACHMENT:
        answers.append(
            {
                "form_id": instance_form_id,
                "form_template_field_id": FIELD_TEACHER_ATTACHMENT,
                "attributes": {"attachments": [DEFAULT_ATTACHMENT]},
            }
        )
    url = f"{SEIUE_BASE}/chalk/chat/chats/{chat_id}/chat-form/{CHAT_FORM_TEMPLATE_ID}/answers"
    debug(f"submit form → chat {chat_id} instance_form {instance_form_id} via template {CHAT_FORM_TEMPLATE_ID}")
    if DRY_RUN:
        debug(f"DRY_RUN form answers: {json.dumps(answers, ensure_ascii=False)}")
        return
    resp = s.post(url, json=answers, timeout=15)
    if not resp.ok:
        debug(f"HTTP {resp.status_code} on submit_chat_form: {resp.text}")
        resp.raise_for_status()


def patch_chat_status(s: "requests.Session", chat_id: int, status: str = "finished"):
    payload = {
        "custom_fields": {
            "reason": "自動補錄約談",
            "open_reservation_again": False,
        },
        "status": status,
    }
    url = f"{SEIUE_BASE}/chalk/chat/instances/{CHAT_INSTANCE_ID}/chats/{chat_id}"
    debug(f"patch status → chat {chat_id} = {status}")
    if DRY_RUN:
        debug(f"DRY_RUN patch: {json.dumps(payload, ensure_ascii=False)}")
        return
    resp = s.patch(url, json=payload, timeout=15)
    if not resp.ok:
        debug(f"HTTP {resp.status_code} on patch_chat_status: {resp.text}")
        resp.raise_for_status()


def main():
    s = make_session()

    record_from_env = os.getenv("SEIUE_RECORD_TEXT", "").strip()
    if record_from_env:
        user_record_text = record_from_env
    else:
        try:
            user_record_text = input("這次要寫入的約談內容(直接 Enter 用預設): ").strip()
        except EOFError:
            user_record_text = ""
    if not user_record_text:
        user_record_text = DEFAULT_RECORD_TEXT

    students = fetch_group_students(s, GROUP_ID, CLASS_ID)
    extra_ids = [int(x) for x in sys.argv[1:] if x.isdigit()]
    students.extend(extra_ids)
    students = list(dict.fromkeys(students))
    debug(f"本次要寫的學生共 {len(students)} 人: {students}")

    for rid in students:
        try:
            chat_id = create_chat(s, rid)
            if chat_id:
                real_form_id = fetch_chat_form_instance_id(s, chat_id)
                submit_chat_form(s, chat_id, user_record_text, real_form_id)
                patch_chat_status(s, chat_id, status="finished")
                debug(f"✓ 完成 student {rid} → chat {chat_id}")
            time.sleep(0.8)
        except Exception as e:
            debug(f"✗ student {rid} 失敗: {e}")

    debug("全部處理完畢")


if __name__ == "__main__":
    main()
PY
  chmod +x "$PY_MAIN"
}

run_python() {
  # shellcheck disable=SC1091
  . "$PY_ENV/bin/activate"
  echo "[mentee] running mentee.py ..."
  python "$PY_MAIN" "$@"
}

main() {
  kill_old
  os="$(detect_os)"
  install_deps "$os"
  prepare_env
  write_python
  run_python "$@"
}

main "$@"