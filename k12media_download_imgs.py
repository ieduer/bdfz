#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
k12media_download_imgs.py

Purpose
-------
1. Download all answer-sheet images for a given exam (testId) under
   a given school (schoolId) and class list.
2. Support BOTH:
   - Class mode: download one subject for all students in listed classes
   - Single-student mode: download ALL subjects (1–9) for a specific student

Data flow (rough)
-----------------
1. Use browser cookies (JSESSIONID / DWRSESSIONID / SERVERID) from
   https://test.k12media.cn  in a requests.Session.
2. For each class (classId), call DWR API:

       SelectSchoolUtil.findStudentListByClassId(testId, schoolId, classId, isTeacherClass)

   to get student list (noInClass + name).
3. For each student, simulate form POST:

       POST /tqms/report/ShowStudentImgsAction.a?findStudentImgs

   to obtain the HTML page that lists answer images in an iframe.
4. From the HTML, extract all <img ... src="...DemoAction.a?showImg..."> URLs.
   These are full-size images served by:

       https://yue.k12media.cn/tqms_image_server/DemoAction.a?showImg&...

5. Download all images, organize by:

       <output_root>/
         <class_label>_<class_id>/
           <noInClass>_<student_name>/
             p01.jpg, p02.jpg, ...
             (optional) subj_<id>_<name> for single-student mode

6. Write an index.csv and a missing.csv at <output_root>.

Usage examples
--------------
Class mode (one subject for all students):

    /Users/ylsuen/.venv/bin/python3 /Users/ylsuen/bin/k12media_download_imgs.py \
        /Users/ylsuen/Desktop/yue_imgs \
        --subject-id 3

Single student, all subjects 1–9:

    /Users/ylsuen/.venv/bin/python3 /Users/ylsuen/bin/k12media_download_imgs.py \
        /Users/ylsuen/Desktop/yue_imgs \
        --student-name 張三  
        or
        --student-no 2722134         

"""

import sys
import csv
import re
import time
import pathlib
import urllib.parse
import argparse
from dataclasses import dataclass
from typing import Dict, List, Tuple, Optional
from html.parser import HTMLParser

import requests

# ============================================================
# 0. Basic configuration
# ============================================================

# --- Sites & paths ---
BASE_URL_MAIN = "https://test.k12media.cn"  # main system (classes, students, iframe)
BASE_URL_IMG = "https://yue.k12media.cn"    # image server for DemoAction

SHOW_STUDENT_MAIN_PATH = "/tqms/report/ShowStudentImgsAction.a"
SHOW_STUDENT_FIND_PATH = "/tqms/report/ShowStudentImgsAction.a?findStudentImgs"

# DemoAction image server base
IMG_SERVER_BASE = f"{BASE_URL_IMG}/tqms_image_server/"

# --- Exam / school / state ---
TEST_ID = 119274          # <input id="testId" value="119274">
SCHOOL_ID = 3600          # <input id="schoolId" value="3600">
TEST_STATE = 1            # <input id="testState" value="1">

# Default subjectId (used in class mode if --subject-id not given)
# Subject mapping: 1=Chinese, 2=Math, 3=English, 4=Physics, 5=Chem, 6=Bio, 7=Politics, 8=History, 9=Geography
SUBJECT_ID_DEFAULT = 2

SUBJECT_NAMES: Dict[int, str] = {
    1: "語文",
    2: "數學",
    3: "英語",
    4: "物理",
    5: "化學",
    6: "生物",
    7: "政治",
    8: "歷史",
    9: "地理",
}

SUBJECT_ORDER = [1, 2, 3, 4, 5, 6, 7, 8, 9]

# --- Class list (current exam) ---
@dataclass
class ClassConfig:
    class_id: int
    is_teacher_class: bool  # False=行政班, True=教學班
    label: str


CLASSES: List[ClassConfig] = [
    ClassConfig(class_id=91268,   is_teacher_class=False, label="格物3班"),
    ClassConfig(class_id=91272,   is_teacher_class=False, label="致知3班"),
    ClassConfig(class_id=1883835, is_teacher_class=True,  label="格物3班班"),
    ClassConfig(class_id=1883842, is_teacher_class=True,  label="致知3班班"),
]

# --- Cookie: copy directly from test.k12media.cn (do NOT shorten) ---
RAW_COOKIE = (

)

# --- User-Agent ---
DEFAULT_USER_AGENT = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Safari/537.36"
)

# --- DWR endpoint (plaincall) ---
DWR_STUDENT_LIST_URL = (
    f"{BASE_URL_MAIN}/tqms/dwr/call/plaincall/"
    "SelectSchoolUtil.findStudentListByClassId.dwr"
)

DEBUG_DWR_DUMP = True

# ============================================================
# 1. Utilities
# ============================================================


def parse_cookie_string(cookie_str: str) -> Dict[str, str]:
    """
    Convert "k1=v1; k2=v2" cookie header string into dict for requests.
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
    Extract DWRSESSIONID from RAW_COOKIE.
    If missing, fall back to a timestamp-based fake one.
    """
    m = re.search(r"DWRSESSIONID=([^;]+)", cookie_str)
    if m:
        return m.group(1)
    return str(int(time.time() * 1000))


def safe_filename(name: str) -> str:
    """
    Make class/ student names safe for filesystem.
    """
    name = name.strip()
    for ch in "\\/:*?\"<>|":
        name = name.replace(ch, "_")
    return name


def ensure_dir(path: pathlib.Path) -> None:
    path.mkdir(parents=True, exist_ok=True)


# ============================================================
# 2. DWR: fetch student list
# ============================================================


def build_dwr_body_for_student_list(
    test_id: int,
    school_id: int,
    class_id: int,
    is_teacher_class: bool,
    dwr_session_id: str,
) -> str:
    """
    Construct DWR body for SelectSchoolUtil.findStudentListByClassId
    based on the real traffic pattern you captured.

    Example captured body (for another method):

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
        scriptSessionId=sz0z1bmj.../1710000000000

    Here we only change methodName + param count, keep structure.
    """
    teacher_flag = "1" if is_teacher_class else "0"
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
    Convert \\uXXXX from DWR response into real Unicode characters.
    """
    try:
        return bytes(s, "utf-8").decode("unicode_escape")
    except Exception:
        return s


def parse_dwr_student_list(
    text: str,
    class_cfg: ClassConfig,
) -> List[Student]:
    """
    Parse DWR response into Student objects.

    Real structure example:

        dwr.engine.remote.handleCallback("1","0",
        [
          {classId:91268,
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

    We match three fields using a cross-line, non-greedy regex:

        classId:(\\d+)
        noInClass:"(....)"
        orgUser:{ ... name:"(....)" ...

    Then decode name's \\uXXXX.
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
    Call DWR API to fetch students in one class.
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

    # Server uses text/javascript; charset=ISO-8859-1
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
# 3. Fetch student's image HTML and extract DemoAction URLs
# ============================================================

class ImgSrcParser(HTMLParser):
    """
    HTMLParser-based extractor for <img src="...">.
    More robust than regex for slightly messy HTML.

    We only care about src attributes; filtering for DemoAction
    is done in extract_demoaction_urls().
    """

    def __init__(self) -> None:
        super().__init__()
        self.srcs: List[str] = []

    def handle_starttag(self, tag: str, attrs):
        if tag.lower() != "img":
            return
        for (k, v) in attrs:
            if k.lower() == "src" and v:
                self.srcs.append(v)
                break


def fetch_student_img_html(
    session: requests.Session,
    student: Student,
    subject_id: int,
) -> str:
    """
    Simulate form POST:
        POST ShowStudentImgsAction.a?findStudentImgs
    to obtain the image-page HTML for one student & subject.

    Fields match what the real form submits.
    """
    url = f"{BASE_URL_MAIN}{SHOW_STUDENT_FIND_PATH}"

    data = {
        "schoolId": str(SCHOOL_ID),
        "testId": str(TEST_ID),
        "testState": str(TEST_STATE),
        "studentName": student.name,
        "classId": str(student.class_id),
        "isTeacherClass": "1" if student.is_teacher_class else "0",
        "subjectId": str(subject_id),
    }

    headers = {
        "User-Agent": DEFAULT_USER_AGENT,
        "Origin": BASE_URL_MAIN,
        "Referer": f"{BASE_URL_MAIN}{SHOW_STUDENT_MAIN_PATH}",
    }

    subj_name = SUBJECT_NAMES.get(subject_id, "")
    print(
        f"[info]  拉圖片頁：{student.class_label} "
        f"{student.no_in_class} {student.name} (科目{subject_id} {subj_name})"
    )
    resp = session.post(url, headers=headers, data=data, timeout=20)
    resp.raise_for_status()
    resp.encoding = resp.encoding or "utf-8"
    return resp.text


def extract_demoaction_urls(html: str) -> List[str]:
    """
    Extract all DemoAction.a?showImg... src URLs from HTML.

    This is the FIXED version:

    - Uses HTMLParser (ImgSrcParser) to get src attributes from all <img> tags
      instead of relying on a single regex over raw HTML text.
    - Accepts both absolute URLs:
        https://yue.k12media.cn/tqms_image_server/DemoAction.a?showImg...
      and relative URLs:
        /tqms_image_server/DemoAction.a?showImg...
    """
    parser = ImgSrcParser()
    parser.feed(html)

    results: List[str] = []
    seen: set = set()

    for raw in parser.srcs:
        s = (raw or "").strip()
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
# 4. Download DemoAction images (showImg)
# ============================================================


def download_demoaction_image(
    session: requests.Session,
    src: str,
) -> Tuple[bytes, str]:
    """
    Given src (absolute or relative), download the image and return (bytes, content_type).
    """
    if src.lower().startswith("http://") or src.lower().startswith("https://"):
        url = src
    else:
        # If the HTML used relative src="/tqms_image_server/...", urljoin will handle it.
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


def save_debug_html(
    base_dir: pathlib.Path,
    subject_id: Optional[int],
    html: str,
) -> None:
    """
    Save HTML for debugging when no DemoAction images are found
    or when fetch fails. This mirrors what you were already doing.
    """
    try:
        ensure_dir(base_dir)
        if subject_id is None:
            fname = "_debug.html"
        else:
            fname = f"_debug_subject_{subject_id}.html"
        debug_path = base_dir / fname
        debug_path.write_text(html, encoding="utf-8")
        print(
            f"[debug] 已保存 HTML 到 {debug_path}，可對照報文檢查參數是否一致"
        )
    except Exception as e:
        print(f"[debug] 保存 HTML 失敗：{e}")


# ============================================================
# 5. Main flows: class mode & single-student mode
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


def run_class_mode(
    session: requests.Session,
    out_root: pathlib.Path,
    students: List[Student],
    subject_id: int,
    index_writer: csv.writer,
    missing_writer: csv.writer,
) -> Tuple[int, int]:
    """
    Download one subject for all students (class mode).
    """
    total_students = 0
    total_imgs = 0

    subj_name = SUBJECT_NAMES.get(subject_id, "")
    print("---------------------------------------------------")
    print(f"[info] 班級模式：只下載 subjectId={subject_id} {subj_name}")

    for stu in students:
        total_students += 1
        class_dir_name = f"{safe_filename(stu.class_label)}_{stu.class_id}"
        student_dir_name = f"{stu.no_in_class}_{safe_filename(stu.name)}"
        stu_dir = out_root / class_dir_name / student_dir_name
        ensure_dir(stu_dir)

        try:
            html = fetch_student_img_html(session, stu, subject_id)
        except Exception as e:
            print(
                f"[warn]  拉圖片頁失敗：{stu.class_label} {stu.no_in_class} {stu.name} "
                f"(科目 {subject_id}) ({e})"
            )
            missing_writer.writerow([
                stu.class_id,
                stu.class_label,
                int(stu.is_teacher_class),
                stu.no_in_class,
                stu.name,
                f"fetch_html_error_subject_{subject_id}: {e}",
            ])
            save_debug_html(stu_dir, subject_id, f"ERROR fetch_html: {e}\n")
            continue

        demo_srcs = extract_demoaction_urls(html)
        if not demo_srcs:
            print(
                f"[warn]  找不到 DemoAction 圖片：{stu.class_label} "
                f"{stu.no_in_class} {stu.name} (科目 {subject_id})"
            )
            missing_writer.writerow([
                stu.class_id,
                stu.class_label,
                int(stu.is_teacher_class),
                stu.no_in_class,
                stu.name,
                f"no_demoaction_img_subject_{subject_id}",
            ])
            save_debug_html(stu_dir, subject_id, html)
            continue

        print(
            f"[info]  {stu.class_label} {stu.no_in_class} {stu.name} "
            f"共 {len(demo_srcs)} 張 (科目 {subject_id})"
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
            index_writer.writerow([
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

        time.sleep(0.3)

    return total_students, total_imgs


def run_single_student_all_subjects(
    session: requests.Session,
    out_root: pathlib.Path,
    stu: Student,
    index_writer: csv.writer,
    missing_writer: csv.writer,
) -> Tuple[int, int]:
    """
    Download ALL subjects (1–9) for a single student.
    Each subject will be placed under:

        <class_label>_<class_id>/<no>_<name>/subj_<id>_<subject_name>/

    with p01.jpg, p02.jpg, ...
    """
    total_students = 1
    total_imgs = 0

    class_dir_name = f"{safe_filename(stu.class_label)}_{stu.class_id}"
    student_dir_name = f"{stu.no_in_class}_{safe_filename(stu.name)}"
    stu_dir = out_root / class_dir_name / student_dir_name
    ensure_dir(stu_dir)

    print(f"[info]  目標學生：{stu.class_label} {stu.no_in_class} {stu.name}")
    print("---------------------------------------------------")

    for subject_id in SUBJECT_ORDER:
        subj_name = SUBJECT_NAMES.get(subject_id, f"科目{subject_id}")
        print("---------------------------------------------------")
        print(f"[info] 處理科目 {subject_id} {subj_name}")

        subj_dir = stu_dir / f"subj_{subject_id}_{safe_filename(subj_name)}"
        ensure_dir(subj_dir)

        try:
            html = fetch_student_img_html(session, stu, subject_id)
        except Exception as e:
            print(
                f"[warn]  拉圖片頁失敗：{stu.class_label} {stu.no_in_class} {stu.name} "
                f"(科目 {subject_id} {subj_name}) ({e})"
            )
            missing_writer.writerow([
                stu.class_id,
                stu.class_label,
                int(stu.is_teacher_class),
                stu.no_in_class,
                stu.name,
                f"fetch_html_error_subject_{subject_id}: {e}",
            ])
            save_debug_html(subj_dir, subject_id, f"ERROR fetch_html: {e}\n")
            continue

        demo_srcs = extract_demoaction_urls(html)
        if not demo_srcs:
            print(
                f"[warn]  找不到 DemoAction 圖片：{stu.class_label} "
                f"{stu.no_in_class} {stu.name} (科目 {subject_id} {subj_name})"
            )
            missing_writer.writerow([
                stu.class_id,
                stu.class_label,
                int(stu.is_teacher_class),
                stu.no_in_class,
                stu.name,
                f"no_demoaction_img_subject_{subject_id}",
            ])
            save_debug_html(subj_dir, subject_id, html)
            continue

        print(
            f"[info]  {stu.class_label} {stu.no_in_class} {stu.name} "
            f"共 {len(demo_srcs)} 張 (科目 {subject_id} {subj_name})"
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
            out_path = subj_dir / filename

            with open(out_path, "wb") as f:
                f.write(data)

            total_imgs += 1
            index_writer.writerow([
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

        time.sleep(0.3)

    return total_students, total_imgs


# ============================================================
# 6. CLI entry
# ============================================================


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Download k12media answer-sheet images (class mode or single-student mode).",
    )
    parser.add_argument(
        "output_dir",
        help="Output directory to store images and CSV index.",
    )
    parser.add_argument(
        "--subject-id",
        type=int,
        help="Subject ID when running class mode only (1–9).",
    )
    parser.add_argument(
        "--student-no",
        help="noInClass of target student (enables single-student mode if set together with/without --student-name).",
    )
    parser.add_argument(
        "--student-name",
        help="Name of target student in Chinese, exact match (enables single-student mode if set).",
    )

    args = parser.parse_args()

    out_root = pathlib.Path(args.output_dir).expanduser()
    ensure_dir(out_root)

    if not RAW_COOKIE.strip():
        print("[error] RAW_COOKIE is empty; please paste cookie from test.k12media.cn at top of script.")
        sys.exit(1)

    student_no = (args.student_no or "").strip()
    student_name = (args.student_name or "").strip()

    if student_no or student_name:
        print("[info] 啟用：單一學生全科目模式")
        print(f"[info]  student_no='{student_no}', student_name='{student_name}'")
    else:
        print("[info] 啟用：班級模式（按 subjectId 批量下載）")

    print(f"[info] 輸出根目錄：{out_root}")

    session = create_session()
    dwr_session_id = extract_dwr_session_id(RAW_COOKIE)

    # 1) fetch all students from all configured classes
    all_students: List[Student] = []
    for class_cfg in CLASSES:
        try:
            students = fetch_students_for_class(session, class_cfg, dwr_session_id)
        except Exception as e:
            print(f"[warn] 拉學生列表失敗：class_id={class_cfg.class_id} ({e})")
            continue
        all_students.extend(students)

    print(f"[info] 全部班級合計學生數：{len(all_students)}")

    # deduplicate students by (class_id, no_in_class, name)
    seen_keys = set()
    unique_students: List[Student] = []
    for s in all_students:
        key = (s.class_id, s.no_in_class, s.name)
        if key in seen_keys:
            continue
        seen_keys.add(key)
        unique_students.append(s)

    print(f"[info] 去重後學生數：{len(unique_students)}")

    # 2) prepare CSV files
    index_path = out_root / "index.csv"
    index_file = open(index_path, "w", encoding="utf-8", newline="")
    index_writer = csv.writer(index_file)
    index_writer.writerow([
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

    total_students = 0
    total_imgs = 0

    # 3) decide mode: single-student vs class
    if student_no or student_name:
        # --- single-student mode ---
        candidates: List[Student] = []

        for s in unique_students:
            if student_no and s.no_in_class != student_no:
                continue
            if student_name and s.name != student_name:
                continue
            candidates.append(s)

        if not candidates:
            print("[error] 找不到符合條件的學生，請檢查學號 / 姓名 是否正確。")
            index_file.close()
            missing_file.close()
            sys.exit(1)

        if len(candidates) > 1:
            print("[error] 匹配到多個學生，請加上 --student-no 精確指定：")
            for s in candidates:
                print(f"  - {s.class_label} {s.no_in_class} {s.name}")
            index_file.close()
            missing_file.close()
            sys.exit(1)

        target = candidates[0]
        stu_count, img_count = run_single_student_all_subjects(
            session,
            out_root,
            target,
            index_writer,
            missing_writer,
        )
        total_students += stu_count
        total_imgs += img_count

    else:
        # --- class mode ---
        subject_id = args.subject_id or SUBJECT_ID_DEFAULT
        stu_count, img_count = run_class_mode(
            session,
            out_root,
            unique_students,
            subject_id,
            index_writer,
            missing_writer,
        )
        total_students += stu_count
        total_imgs += img_count

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