#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
k12media_full_download.py / k12media_download_imgs.py

目的：
    自動把 某次考試（testId）下，指定學校(schoolId)、指定班級列表 的
    「學生答卷圖片」全部爬完，存到本地，並生成 index.csv 索引。

整體流程：
    1. 帶上瀏覽器 Cookie（含 JSESSIONID / DWRSESSIONID / SERVERID），用 Session
       連 test.k12media.cn（⚠️ 必須是這個 Host 的 Cookie）
    2. 對每個班級 classId 調 DWR 介面：
         SelectSchoolUtil.findStudentListByClassId(testId, schoolId, classId, isTeacherClass)
       拿到全班學生列表（學號 noInClass + 姓名）
    3. 對每個學生模擬頁面表單：
         POST /tqms/report/ShowStudentImgsAction.a?findStudentImgs
       取得該生的「圖片頁」HTML
    4. 從 HTML 中抽出 <img src="DemoAction.a?showImg&imgFliePath=..."> 這些 URL
       拼出完整的圖片伺服器 URL：
         https://yue.k12media.cn/tqms_image_server/DemoAction.a?showImg&...
    5. 下載所有圖片，按 班級/學號/姓名/頁碼 組織檔名，保存 + 寫入 index.csv
       同時把「沒抓到任何圖片的學生」記錄到 missing.csv 裡。


用法（例）：
    /Users/ylsuen/.venv/bin/python3 /Users/ylsuen/bin/k12media_download_imgs.py \
        /Users/ylsuen/Desktop/yue_imgs
"""

import sys
import csv
import re
import time
import pathlib
import urllib.parse
from dataclasses import dataclass
from typing import Dict, List, Tuple

import requests

# ============================================================
# 0. 基本配置區
# ============================================================

# --- 站點與路徑 ---
BASE_URL_MAIN = "https://test.k12media.cn"  # 左側班級/學生 + iframe 主系統
BASE_URL_IMG = "https://yue.k12media.cn"    # 圖片 DemoAction 伺服器

SHOW_STUDENT_MAIN_PATH = "/tqms/report/ShowStudentImgsAction.a"
SHOW_STUDENT_FIND_PATH = "/tqms/report/ShowStudentImgsAction.a?findStudentImgs"

# DemoAction 圖片服務 base，用來拼 showImg URL
IMG_SERVER_BASE = f"{BASE_URL_IMG}/tqms_image_server/"

# --- 考試 / 學校 / 科目配置 ---
TEST_ID = 119274          # <input id="testId" value="119274">
SCHOOL_ID = 3600          # <input id="schoolId" value="3600">
TEST_STATE = 1            # <input id="testState" value="1">
SUBJECT_ID = 1            # 1=語文

# --- 班級列表  ---
@dataclass
class ClassConfig:
    class_id: int
    is_teacher_class: bool  # False=行政班, True=教學班
    label: str


CLASSES: List[ClassConfig] = [
    ClassConfig(class_id=91266,   is_teacher_class=False, label="格物1班"),
    ClassConfig(class_id=91267,   is_teacher_class=False, label="格物2班"),
    ClassConfig(class_id=91270,   is_teacher_class=False, label="致知1班"),
    ClassConfig(class_id=91271,   is_teacher_class=False, label="致知2班"),
    ClassConfig(class_id=91268,   is_teacher_class=False, label="格物3班"),
    ClassConfig(class_id=91272,   is_teacher_class=False, label="致知3班"),
    ClassConfig(class_id=1883835, is_teacher_class=True,  label="格物3班班"),
    ClassConfig(class_id=1883842, is_teacher_class=True,  label="致知3班班"),
]

# --- Cookie：⚠️ 
RAW_COOKIE = (

)

# --- User-Agent（可以用你真實的 UA，不一定要 Android 模式） ---
DEFAULT_USER_AGENT = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Safari/537.36"
)

# --- DWR 端點：plaincall ---
DWR_STUDENT_LIST_URL = (
    f"{BASE_URL_MAIN}/tqms/dwr/call/plaincall/"
    "SelectSchoolUtil.findStudentListByClassId.dwr"
)

# 若要 debug DWR response，可開 True
DEBUG_DWR_DUMP = True

# ============================================================
# 1. 小工具
# ============================================================

def parse_cookie_string(cookie_str: str) -> Dict[str, str]:
    """
    把 "k1=v1; k2=v2" 這種 header 形式轉成 dict 給 requests 用。
    """
    cookie_str = cookie_str.strip()
    cookies: Dict[str, str] = {}
    if not cookie_str:
        return cookies
    parts = cookie_str.split(";")
    for part in parts:
        part = part.strip()
        if not part or "=" not in part:
            continue
        k, v = part.split("=", 1)
        cookies[k.strip()] = v.strip()
    return cookies


def extract_dwr_session_id(cookie_str: str) -> str:
    """
    從 RAW_COOKIE 裡抓出 DWRSESSIONID（如果沒有，就隨機給一個）。
    """
    m = re.search(r"DWRSESSIONID=([^;]+)", cookie_str)
    if m:
        return m.group(1)
    # 沒找到就退而求其次用 timestamp
    return str(int(time.time() * 1000))


def safe_filename(name: str) -> str:
    """
    把姓名/班級字串變成安全的檔名片段。
    """
    name = name.strip()
    for ch in "\\/:*?\"<>|":
        name = name.replace(ch, "_")
    return name


def ensure_dir(path: pathlib.Path) -> None:
    path.mkdir(parents=True, exist_ok=True)


# ============================================================
# 2. DWR 相關：拿學生列表
# ============================================================

def build_dwr_body_for_student_list(
    test_id: int,
    school_id: int,
    class_id: int,
    is_teacher_class: bool,
    dwr_session_id: str,
) -> str:
    """
    根據你實際抓到的 DWR 格式來構造 findStudentListByClassId 的 body。

    參照報文（findStudentPersonScoreByNoInClass）：

        callCount=1
        nextReverseAjaxIndex=0
        c0-scriptName=SelectSchoolUtil
        c0-methodName=findStudentPersonScoreByNoInClass
        c0-id=0
        c0-param0=string:119274
        c0-param1=string:1
        c0-param2=string:2721131
        batchId=1
        instanceId=0
        page=/tqms/report/ShowStudentImgsAction.a
        scriptSessionId=sz0z1bmjX86tS79Ud10CnAVg6htD9Kk39Gp/......

    這裡只改 methodName + 參數個數，其餘結構保持一致。
    """
    teacher_flag = "1" if is_teacher_class else "0"
    # scriptSessionId 用 DWRSESSIONID 做前綴，後面拼一個毫秒級尾巴
    script_session_id = f"{dwr_session_id}/{int(time.time() * 1000)}"

    body_lines = [
        "callCount=1",
        "nextReverseAjaxIndex=0",
        "c0-scriptName=SelectSchoolUtil",
        "c0-methodName=findStudentListByClassId",
        "c0-id=0",
        f"c0-param0=string:{test_id}",
        f"c0-param1=string:{school_id}",
        f"c0-param2=string:{class_id}",
        f"c0-param3=string:{teacher_flag}",
        "batchId=1",
        "instanceId=0",
        "page=/tqms/report/ShowStudentImgsAction.a",
        f"scriptSessionId={script_session_id}",
    ]
    return "\n".join(body_lines)


@dataclass
class Student:
    class_id: int
    class_label: str
    is_teacher_class: bool
    no_in_class: str
    name: str


def _decode_dwr_unicode(s: str) -> str:
    """
    把 DWR 回應裡的 \\uXXXX 轉成真正的 Unicode 字元。
    """
    try:
        # 原始字符串裡是 \u4E2D 這種形式
        return bytes(s, "utf-8").decode("unicode_escape")
    except Exception:
        return s


def parse_dwr_student_list(
    text: str,
    class_cfg: ClassConfig,
) -> List[Student]:
    """
    從 DWR 回應文字裡解析出 Student 陣列。

    真實結構示例（你剛剛抓到的）：

        dwr.engine.remote.handleCallback("1","0",
        [
          {classId:91268,
           classStudentId:4390697,
           ...
           noInClass:"2721101",
           orgStudent:{
             ...
             orgUser:{...,name:"\\u9648\\u6734\\u601D",...},
           },
           schoolId:3600,
           score:null},
          {...},
          ...
        ]);

    我們用一個跨行、非貪婪 regex 捕三個欄位：

        classId:(\\d+)
        noInClass:"(....)"
        orgUser:{ ... name:"(....)" ...

    然後把 name 的 \\uXXXX 做一次 unicode_escape 解碼。
    """
    pattern = re.compile(
        r"classId:(\d+),.*?noInClass:\"([^\"]+)\".*?orgUser:\{.*?name:\"([^\"]+)\"",
        re.DOTALL,
    )

    students: List[Student] = []

    for m in pattern.finditer(text):
        class_id_str, no_in_class, raw_name = m.groups()
        class_id = int(class_id_str)
        name = _decode_dwr_unicode(raw_name)

        students.append(
            Student(
                class_id=class_id,
                class_label=class_cfg.label,
                is_teacher_class=class_cfg.is_teacher_class,
                no_in_class=no_in_class,
                name=name,
            )
        )

    return students


def fetch_students_for_class(
    session: requests.Session,
    class_cfg: ClassConfig,
    dwr_session_id: str,
) -> List[Student]:
    """
    調 DWR 介面拿某班所有學生。
    """
    body = build_dwr_body_for_student_list(
        test_id=TEST_ID,
        school_id=SCHOOL_ID,
        class_id=class_cfg.class_id,
        is_teacher_class=class_cfg.is_teacher_class,
        dwr_session_id=dwr_session_id,
    )

    headers = {
        "User-Agent": DEFAULT_USER_AGENT,
        "Content-Type": "text/plain",
        "Accept": "*/*",
        "Origin": BASE_URL_MAIN,
        "Referer": f"{BASE_URL_MAIN}{SHOW_STUDENT_MAIN_PATH}",
        "Cache-Control": "no-cache",
        "Pragma": "no-cache",
    }

    print(
        f"[info] DWR 拉學生列表：class_id={class_cfg.class_id} "
        f"({class_cfg.label}, teacher={int(class_cfg.is_teacher_class)})"
    )
    resp = session.post(DWR_STUDENT_LIST_URL, headers=headers, data=body, timeout=20)
    resp.raise_for_status()

    # 伺服器回應是 text/javascript; charset=ISO-8859-1
    resp.encoding = resp.encoding or "iso-8859-1"
    text = resp.text

    if DEBUG_DWR_DUMP:
        print("----- DWR response head -----")
        print(text[:1000])
        print("----- DWR response end ------")

    students = parse_dwr_student_list(text, class_cfg)
    print(f"[info]  班級 {class_cfg.label}({class_cfg.class_id}) → 學生數：{len(students)}")
    return students


# ============================================================
# 3. 拿每個學生的圖片頁 HTML，解析 DemoAction URL
# ============================================================

IMG_TAG_SRC_RE = re.compile(
    r'<img[^>]+src=["\']([^"\']+)["\']',
    re.IGNORECASE,
)


def fetch_student_img_html(
    session: requests.Session,
    student: Student,
) -> str:
    """
    模擬頁面 form submit：
        POST ShowStudentImgsAction.a?findStudentImgs
    拿到學生圖片頁（在 iframe 裡的那一頁）。
    """
    url = f"{BASE_URL_MAIN}{SHOW_STUDENT_FIND_PATH}"

    data = {
        "schoolId": str(SCHOOL_ID),
        "testId": str(TEST_ID),
        "testState": str(TEST_STATE),
        "studentName": student.name,
        "classId": str(student.class_id),
        "isTeacherClass": "1" if student.is_teacher_class else "0",
        "subjectId": str(SUBJECT_ID),
    }

    headers = {
        "User-Agent": DEFAULT_USER_AGENT,
        "Origin": BASE_URL_MAIN,
        "Referer": f"{BASE_URL_MAIN}{SHOW_STUDENT_MAIN_PATH}",
    }

    print(
        f"[info]  拉圖片頁：{student.class_label} "
        f"{student.no_in_class} {student.name}"
    )
    resp = session.post(url, headers=headers, data=data, timeout=20)
    resp.raise_for_status()
    resp.encoding = resp.encoding or "utf-8"
    return resp.text


def extract_demoaction_urls(html: str) -> List[str]:
    """
    從圖片頁 HTML 裡抽出 DemoAction.a?showImg... 的 src。
    傳回相對 URL 列表（之後再用 BASE_URL_IMG 拼成完整 URL）。
    """
    srcs = IMG_TAG_SRC_RE.findall(html)
    results: List[str] = []
    seen = set()

    for s in srcs:
        s = s.strip()
        if not s:
            continue
        if "DemoAction.a" not in s:
            continue
        if s in seen:
            continue
        seen.add(s)
        results.append(s)

    return results


# ============================================================
# 4. 下載 DemoAction 圖片（showImg）
# ============================================================

def download_demoaction_image(
    session: requests.Session,
    src: str,
) -> Tuple[bytes, str]:
    """
    根據 src（可能是相對路徑）下載圖片，返回 (bytes, content_type)。
    """
    if src.lower().startswith("http://") or src.lower().startswith("https://"):
        url = src
    else:
        url = urllib.parse.urljoin(IMG_SERVER_BASE, src)

    headers = {
        "User-Agent": DEFAULT_USER_AGENT,
        "Referer": f"{BASE_URL_MAIN}{SHOW_STUDENT_FIND_PATH}",
    }

    resp = session.get(url, headers=headers, timeout=30)
    resp.raise_for_status()
    content_type = resp.headers.get("Content-Type", "").lower()
    return resp.content, content_type


def guess_ext_from_content_type(content_type: str) -> str:
    if not content_type:
        return ".jpg"
    if content_type.startswith("image/"):
        subtype = content_type.split("/", 1)[1]
        subtype = subtype.split(";", 1)[0].strip().lower()
        if subtype in ("jpeg", "jpg"):
            return ".jpg"
        if subtype == "png":
            return ".png"
        if subtype == "gif":
            return ".gif"
    return ".jpg"


# ============================================================
# 5. 主流程
# ============================================================

def create_session() -> requests.Session:
    session = requests.Session()
    session.headers.update({
        "User-Agent": DEFAULT_USER_AGENT,
    })
    cookies = parse_cookie_string(RAW_COOKIE)
    if cookies:
        session.cookies.update(cookies)
    return session


def main() -> None:
    if len(sys.argv) != 2:
        print("用法：")
        print("  python3 k12media_download_imgs.py <output_dir>")
        sys.exit(1)

    out_root = pathlib.Path(sys.argv[1]).expanduser()
    ensure_dir(out_root)

    if not RAW_COOKIE.strip():
        print("[error] RAW_COOKIE 還是空的，請在腳本頂部填上從 test.k12media.cn 抓到的 Cookie。")
        sys.exit(1)

    print(f"[info] 輸出根目錄：{out_root}")

    session = create_session()
    dwr_session_id = extract_dwr_session_id(RAW_COOKIE)

    # index.csv 在根目錄
    index_path = out_root / "index.csv"
    index_file = open(index_path, "w", encoding="utf-8", newline="")
    writer = csv.writer(index_file)
    writer.writerow([
        "test_id",
        "school_id",
        "class_id",
        "class_label",
        "is_teacher_class",
        "no_in_class",
        "student_name",
        "page_index",
        "local_path",
        "src_url",
    ])

    # missing.csv：沒有任何 DemoAction 圖片的學生
    missing_path = out_root / "missing.csv"
    missing_file = open(missing_path, "w", encoding="utf-8", newline="")
    missing_writer = csv.writer(missing_file)
    missing_writer.writerow([
        "class_id",
        "class_label",
        "is_teacher_class",
        "no_in_class",
        "student_name",
        "reason",
    ])

    total_imgs = 0
    total_students = 0

    # 1) 先把所有班級學生拉出來
    all_students: List[Student] = []
    for class_cfg in CLASSES:
        try:
            students = fetch_students_for_class(session, class_cfg, dwr_session_id)
        except Exception as e:
            print(f"[warn] 拉學生列表失敗：class_id={class_cfg.class_id} ({e})")
            continue
        all_students.extend(students)

    print(f"[info] 全部班級合計學生數：{len(all_students)}")

    # 去重：(class_id, no_in_class, name)
    seen_keys = set()
    unique_students: List[Student] = []
    for s in all_students:
        key = (s.class_id, s.no_in_class, s.name)
        if key in seen_keys:
            continue
        seen_keys.add(key)
        unique_students.append(s)

    print(f"[info] 去重後學生數：{len(unique_students)}")

    # 2) 逐個學生拉圖片頁 + 下載 DemoAction 圖片
    for stu in unique_students:
        total_students += 1
        class_dir_name = f"{safe_filename(stu.class_label)}_{stu.class_id}"
        student_dir_name = f"{stu.no_in_class}_{safe_filename(stu.name)}"
        stu_dir = out_root / class_dir_name / student_dir_name
        ensure_dir(stu_dir)

        try:
            html = fetch_student_img_html(session, stu)
        except Exception as e:
            print(f"[warn]  拉圖片頁失敗：{stu.class_label} {stu.no_in_class} {stu.name} ({e})")
            missing_writer.writerow([
                stu.class_id,
                stu.class_label,
                int(stu.is_teacher_class),
                stu.no_in_class,
                stu.name,
                f"fetch_html_error: {e}",
            ])
            continue

        demo_srcs = extract_demoaction_urls(html)
        if not demo_srcs:
            print(f"[warn]  找不到 DemoAction 圖片：{stu.class_label} {stu.no_in_class} {stu.name}")
            missing_writer.writerow([
                stu.class_id,
                stu.class_label,
                int(stu.is_teacher_class),
                stu.no_in_class,
                stu.name,
                "no_demoaction_img",
            ])
            continue

        print(
            f"[info]  {stu.class_label} {stu.no_in_class} {stu.name} "
            f"共 {len(demo_srcs)} 張"
        )

        page_idx = 1
        for src in demo_srcs:
            try:
                data, content_type = download_demoaction_image(session, src)
            except Exception as e:
                print(f"[warn]   下載失敗：{src} ({e})")
                continue

            ext = guess_ext_from_content_type(content_type)
            filename = f"p{page_idx:02d}{ext}"
            out_path = stu_dir / filename

            with open(out_path, "wb") as f:
                f.write(data)

            total_imgs += 1
            writer.writerow([
                TEST_ID,
                SCHOOL_ID,
                stu.class_id,
                stu.class_label,
                int(stu.is_teacher_class),
                stu.no_in_class,
                stu.name,
                page_idx,
                str(out_path.relative_to(out_root)),
                src,
            ])
            print(f"[ok]    [{page_idx}] -> {out_path}")
            page_idx += 1

        # 避免太兇，稍微睡一下
        time.sleep(0.3)

    index_file.close()
    missing_file.close()

    print("===================================================")
    print(f"[done] 總學生數：{total_students}")
    print(f"[done] 總下載圖片張數：{total_imgs}")
    print(f"[done] 索引檔：{index_path}")
    print(f"[done] 缺失學生列表：{missing_path}")
    print("===================================================")


if __name__ == "__main__":
    main()