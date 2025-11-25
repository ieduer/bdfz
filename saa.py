#!/usr/bin/env python3
# -*- coding: utf-8 -*-

# --- Core Libraries ---
import json
import logging
import os
import sys
import time
import random
from datetime import datetime, timedelta
from collections import defaultdict

# --- Third-party Libraries ---
import pytz
import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

# --- 1. Credential Configuration ---
SEIUE_USERNAME = os.getenv("SEIUE_USERNAME") or ""
SEIUE_PASSWORD = os.getenv("SEIUE_PASSWORD") or ""

# --- Global Configuration ---
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
STATE_FILE = os.path.join(BASE_DIR, "attendance_state.json")
LOG_FILE = os.path.join(BASE_DIR, "apiall.log")
BEIJING_TZ = pytz.timezone("Asia/Shanghai")

# --- Logging Configuration ---
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s.%(msecs)03d - %(levelname)s - %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
    handlers=[
        logging.FileHandler(LOG_FILE, encoding="utf-8", mode="a"),
        logging.StreamHandler(sys.stdout),
    ],
)

def log_summary(date_str, status, message=""):
    logging.info(f"SUMMARY: {date_str} | STATUS: {status} | DETAIL: {message}")

class SeiueAPIClient:
    def __init__(self, username: str, password: str):
        self.username = username
        self.password = password
        self.session = requests.Session()

        retries = Retry(
            total=5,
            backoff_factor=2,
            status_forcelist=(429, 500, 502, 503, 504),
            allowed_methods=frozenset({"HEAD", "GET", "POST", "PUT"})
        )
        self.session.mount("https://", HTTPAdapter(max_retries=retries))

        self.session.headers.update({
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36",
            "Accept": "application/json, text/plain, */*",
        })
        
        # --- API Endpoints ---
        self.login_url = "https://passport.seiue.com/login?school_id=3"
        self.authorize_url = "https://passport.seiue.com/authorize"
        self.events_url_template = "https://api.seiue.com/chalk/calendar/personals/{}/events"
        self.students_url_template = "https://api.seiue.com/scms/class/classes/{}/group-members?expand=reflection&member_type=student"
        self.attendance_submit_url_template = "https://api.seiue.com/sams/attendance/class/{}/records/sync"
        self.verification_url = "https://api.seiue.com/sams/attendance/attendances-info"
        
        self.bearer_token = None
        self.reflection_id = None
    
    # ----------------- Auth helpers -----------------
    def _re_auth(self) -> bool:
        logging.warning("Token expired or invalid (401/403). Attempting to re-authenticate...")
        return self.login_and_get_token()

    def _with_refresh(self, request_fn):
        resp = request_fn()
        if getattr(resp, "status_code", None) in (401, 403):
            if self._re_auth():
                return request_fn()
        return resp

    def _preflight_login_page(self):
        try:
            self.session.get(
                self.login_url,
                headers={
                    "User-Agent": self.session.headers.get("User-Agent", ""),
                    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                },
                timeout=20,
            )
        except requests.RequestException as e:
            logging.debug(f"Preflight GET failed (continuing): {e}")

    def _auth_flow_with_username(self, uname: str) -> bool:
        self._preflight_login_page()
        try:
            login_resp = self.session.post(
                self.login_url,
                headers={
                    "Referer": self.login_url,
                    "Origin": "https://passport.seiue.com",
                    "Content-Type": "application/x-www-form-urlencoded",
                },
                data={"email": uname, "password": self.password},
                timeout=30,
                allow_redirects=True,
            )
        except requests.RequestException as e:
            logging.error(f"Network error during login with '{uname}': {e}")
            return False

        if "chalk" not in login_resp.url and "bindings" not in login_resp.url:
            logging.warning(
                f"Login response URL did not contain 'chalk' or 'bindings'. "
                f"Actual URL: {login_resp.url}. Will still attempt authorize."
            )

        try:
            auth_resp = self.session.post(
                self.authorize_url,
                headers={
                    "Referer": "https://chalk-c3.seiue.com/",
                    "Origin": "https://chalk-c3.seiue.com",
                    "Content-Type": "application/x-www-form-urlencoded",
                    "X-Requested-With": "XMLHttpRequest",
                },
                data={'client_id': 'GpxvnjhVKt56qTmnPWH1sA', 'response_type': 'token'},
                timeout=30,
            )
            if auth_resp.status_code == 401:
                logging.error("Authorize returned 401 for current session.")
                return False
            auth_resp.raise_for_status()
            auth_data = auth_resp.json()
        except requests.RequestException as e:
            logging.error(f"Authorize request failed with '{uname}': {e}")
            return False
        except ValueError:
            logging.error("Authorize response is not JSON; cannot parse token.")
            return False

        self.bearer_token = auth_data.get("access_token")
        self.reflection_id = auth_data.get("active_reflection_id")
        if not (self.bearer_token and self.reflection_id):
            logging.error("Authentication failed: token or reflection_id missing.")
            return False

        self.session.headers.update({
            "Authorization": f"Bearer {self.bearer_token}",
            "x-school-id": "3",
            "x-role": "teacher",
            "x-reflection-id": str(self.reflection_id),
        })
        logging.info(f"Authentication successful using username variant: '{uname}'")
        self.username = uname
        return True

    def login_and_get_token(self) -> bool:
        logging.info("--- Starting Authentication Flow ---")
        tried = []
        for candidate in [self.username, self.username.upper(), self.username.lower()]:
            if candidate in tried:
                continue
            tried.append(candidate)
            if self._auth_flow_with_username(candidate):
                return True
        logging.error(f"All auth attempts failed. Tried username variants: {tried}")
        return False

    # ----------------- Data fetchers -----------------
    def get_scheduled_lessons(self, target_date: datetime):
        logging.info(f"Fetching lesson schedule for {target_date.strftime('%Y-%m-%d')}...")
        start_time_str = target_date.astimezone(BEIJING_TZ).strftime('%Y-%m-%d 00:00:00')
        end_time_str = target_date.astimezone(BEIJING_TZ).strftime('%Y-%m-%d 23:59:59')
        try:
            events_params = {"start_time": start_time_str, "end_time": end_time_str, "expand": "address,initiators"}
            events_url = self.events_url_template.format(self.reflection_id)
            events_resp = self._with_refresh(lambda: self.session.get(events_url, params=events_params, timeout=30))
            events_resp.raise_for_status()
            all_events = events_resp.json() or []
            lessons_to_process = [e for e in all_events if e.get('type') == 'lesson']
            logging.info(f"Found {len(lessons_to_process)} total lessons scheduled for {target_date.strftime('%Y-%m-%d')}.")
            return lessons_to_process
        except requests.RequestException as e:
            logging.error(f"A network error occurred while fetching scheduled lessons: {e}", exc_info=True)
            return None

    def get_checked_attendance_time_ids(self, lessons: list) -> set:
        if not lessons:
            return set()
        relevant_time_ids_str, relevant_biz_ids_str = set(), set()
        for lesson in lessons:
            custom_id = lesson.get("custom", {}).get("id")
            subject_id = lesson.get("subject", {}).get("id")
            if custom_id is not None and subject_id is not None:
                try:
                    relevant_time_ids_str.add(str(int(custom_id)))
                    relevant_biz_ids_str.add(str(int(subject_id)))
                except (ValueError, TypeError):
                    logging.warning(f"Skipping invalid ids for verification: {lesson.get('title')}")
        if not relevant_time_ids_str or not relevant_biz_ids_str:
            logging.info("No valid lesson IDs found to query for checked status.")
            return set()
        params = {
            "attendance_time_id_in": ",".join(sorted(relevant_time_ids_str)),
            "biz_id_in": ",".join(sorted(relevant_biz_ids_str)),
            "biz_type_in": "class",
            "expand": "checked_attendance_time_ids",
            "paginated": "0",
        }
        try:
            resp = self._with_refresh(lambda: self.session.get(self.verification_url, params=params, timeout=30))
            resp.raise_for_status()
            data = resp.json() or []
            checked_ids = set()
            for item in data:
                for i in (item.get("checked_attendance_time_ids") or []):
                    try:
                        checked_ids.add(int(i))
                    except (ValueError, TypeError):
                        logging.warning(f"Skipping non-integer checked_attendance_time_id: {i}")
            logging.info(f"Verification API reports {len(checked_ids)} lessons are already checked.")
            return checked_ids
        except requests.RequestException as e:
            logging.error(f"Could not get checked attendance info from verification API: {e}", exc_info=True)
            return set()

    # ----------------- Submission -----------------
    def submit_attendance_for_lesson_group(self, lesson_group: list):
        if not lesson_group:
            return True
        course_name = lesson_group[0].get('title', 'Unknown Course')
        class_group_id_raw = lesson_group[0].get("subject", {}).get("id")
        if class_group_id_raw is None:
            logging.error(f"Missing class_group_id for '{course_name}'; skipping.")
            return False
        try:
            class_group_id = int(class_group_id_raw)
        except (ValueError, TypeError):
            logging.error(f"Invalid class_group_id '{class_group_id_raw}' for '{course_name}'; skipping.")
            return False

        logging.info(f"--- Processing course group '{course_name}' (ID: {class_group_id}, {len(lesson_group)} sessions) ---")
        try:
            students_url = self.students_url_template.format(class_group_id)
            resp = self._with_refresh(lambda: self.session.get(students_url, timeout=20))
            resp.raise_for_status()
            students = resp.json() or []
        except requests.RequestException as e:
            if isinstance(e, requests.HTTPError) and e.response is not None:
                logging.error(f"HTTP {e.response.status_code} fetching students for '{course_name}': {(e.response.text or '')[:500]}")
            else:
                logging.error(f"Network error fetching students for '{course_name}': {e}")
            return False
        if not students:
            logging.warning(f"No students returned for class {class_group_id}. Considering as 'no action needed'.")
            return True

        records, seen = [], set()
        for lesson in lesson_group:
            time_id_raw = lesson.get("custom", {}).get("id")
            if time_id_raw is None:
                logging.warning(f"Lesson '{lesson.get('title','Unknown')}' missing attendance_time_id; skipping.")
                continue
            try:
                time_id = int(time_id_raw)
            except (ValueError, TypeError):
                logging.warning(f"Invalid attendance_time_id '{time_id_raw}' for lesson '{lesson.get('title','Unknown')}'; skipping.")
                continue
            for s in students:
                owner_id_raw = s.get("reflection", {}).get("id")
                if owner_id_raw is None:
                    logging.warning(f"Student ID '{s.get('id','Unknown')}' missing reflection ID; skipping.")
                    continue
                try:
                    owner_id = int(owner_id_raw)
                except (ValueError, TypeError):
                    logging.warning(f"Invalid owner_id '{owner_id_raw}' for student ID '{s.get('id','Unknown')}'; skipping.")
                    continue
                key = (time_id, owner_id)
                if key not in seen:
                    records.append({"tag": "正常", "attendance_time_id": time_id, "owner_id": owner_id, "source": "web"})
                    seen.add(key)

        if not records:
            logging.error(f"No valid attendance records constructed for '{course_name}'.")
            return False
        
        logging.info(f"Submitting {len(records)} attendance records for '{course_name}' (Class ID: {class_group_id})...")
        submit_url = self.attendance_submit_url_template.format(class_group_id)
        try:
            resp = self._with_refresh(lambda: self.session.put(submit_url, json={"abnormal_notice_roles": [], "attendance_records": records}, timeout=40))
            resp.raise_for_status()
            logging.info(f"Submission accepted by server (HTTP {resp.status_code}).")
        except requests.RequestException as e:
            if isinstance(e, requests.HTTPError) and e.response is not None:
                code, body = e.response.status_code, (e.response.text or "")[:500]
                logging.error(f"HTTP {code} during submission for '{course_name}': {body}")
                if code in (409, 422):
                    logging.warning(f"Submission for '{course_name}' rejected (HTTP {code}), likely window closed.")
                    return "WINDOW_CLOSED"
            else:
                logging.error(f"Network error during submission for '{course_name}': {e}")
            return False
        return True

# ----------------- State Management -----------------
def _save_state(date_obj):
    try:
        with open(STATE_FILE, 'w', encoding='utf-8') as f:
            json.dump({"last_processed_date": date_obj.strftime("%Y%m%d")}, f)
        logging.debug(f"State saved: last_processed_date={date_obj.strftime('%Y%m%d')}")
    except IOError as e:
        logging.warning(f"Could not save state file: {e}.")

def _load_state():
    if not os.path.exists(STATE_FILE):
        return None
    try:
        with open(STATE_FILE, 'r', encoding='utf-8') as f:
            data = json.load(f)
            return BEIJING_TZ.localize(datetime.strptime(data["last_processed_date"], "%Y%m%d"))
    except Exception as e:
        logging.warning(f"Error loading state file: {e}. Starting fresh.")
        return None

def _clear_state():
    try:
        if os.path.exists(STATE_FILE):
            os.remove(STATE_FILE)
            logging.info("Cleared state file.")
    except IOError as e:
        logging.warning(f"Could not clear state file: {e}.")

# ----------------- Orchestration -----------------
def process_day(client: SeiueAPIClient, current_date: datetime):
    date_iso = current_date.strftime('%Y-%m-%d')
    scheduled_lessons = client.get_scheduled_lessons(current_date)
    if scheduled_lessons is None:
        return "API_FETCH_ERROR", "API error fetching lesson schedule"
    if not scheduled_lessons:
        return "NO_CLASS", "No classes scheduled for this day"

    initial_checked_ids = client.get_checked_attendance_time_ids(scheduled_lessons)
    lessons_to_submit_raw = []
    for lesson in scheduled_lessons:
        custom_id_raw = lesson.get("custom", {}).get("id")
        if custom_id_raw is not None:
            try:
                custom_id_int = int(custom_id_raw)
                if custom_id_int not in initial_checked_ids:
                    lessons_to_submit_raw.append(lesson)
            except (ValueError, TypeError):
                logging.warning(f"Skipping lesson with invalid custom_id '{custom_id_raw}' during initial filter: {lesson.get('title')}")
                continue

    if not lessons_to_submit_raw:
        return "NO_ACTION_NEEDED", "All scheduled classes have been attended or are already checked"

    logging.info(f"Found {len(lessons_to_submit_raw)} lessons requiring attendance for {date_iso} after initial check.")
    
    groups_to_submit = defaultdict(list)
    for lesson in lessons_to_submit_raw:
        gid = lesson.get("subject", {}).get("id")
        if gid is not None:
            try:
                groups_to_submit[int(gid)].append(lesson)
            except (ValueError, TypeError):
                logging.warning(f"Skipping lesson with invalid subject_id '{gid}' when grouping for submission: {lesson.get('title')}")
        else:
            logging.warning(f"Lesson '{lesson.get('title')}' missing subject_id; cannot group for submission.")

    if not groups_to_submit:
        return "NOTHING_TO_SUBMIT", "No valid lesson groups found to submit attendance for (all filtered out)."

    submission_results = []
    attempted_attendance_time_ids = set()
    for _, lesson_group in groups_to_submit.items():
        for lesson in lesson_group:
            custom_id_raw = lesson.get("custom", {}).get("id")
            if custom_id_raw is not None:
                try:
                    attempted_attendance_time_ids.add(int(custom_id_raw))
                except (ValueError, TypeError):
                    pass
        submission_results.append(client.submit_attendance_for_lesson_group(lesson_group))

    logging.info(f"Initiating final verification for {date_iso} with short polling...")
    final_checked_ids = set()
    for poll in range(1, 3 + 1):
        logging.info(f"Verification poll #{poll}...")
        current_checked_ids = client.get_checked_attendance_time_ids(scheduled_lessons)
        if current_checked_ids is None:
            return "VERIFY_FAILED", f"Verification API error during polling attempt {poll}"
        if all(tid in current_checked_ids for tid in attempted_attendance_time_ids):
            final_checked_ids = current_checked_ids
            break
        if poll < 3:
            time.sleep(5)

    still_pending_after_submission = []
    for lesson in lessons_to_submit_raw:
        custom_id_raw = lesson.get("custom", {}).get("id")
        if custom_id_raw is not None:
            try:
                custom_id_int = int(custom_id_raw)
                if custom_id_int in attempted_attendance_time_ids and custom_id_int not in final_checked_ids:
                    still_pending_after_submission.append(lesson)
            except (ValueError, TypeError):
                pass

    if not still_pending_after_submission:
        successful_submissions = sum(1 for res in submission_results if res is True)
        window_closed_warnings = sum(1 for res in submission_results if res == "WINDOW_CLOSED")
        msg = f"Successfully submitted and verified attendance for {successful_submissions} course group(s)."
        if window_closed_warnings > 0:
            msg += f" ({window_closed_warnings} group(s) reported 'window closed' but are now verified as checked)."
            return "SUCCESS_WITH_WARNINGS", msg
        return "SUCCESS", msg
    else:
        n = len(still_pending_after_submission)
        details = ", ".join([
            f"{l.get('title', 'Unknown Lesson')} (ID: {l.get('custom', {}).get('id', 'N/A')})"
            for l in still_pending_after_submission[:5]
        ])
        logging.error(f"VERIFICATION FAILED: {n} lessons still show as pending after submission and re-check.")
        logging.error(f"Pending lessons include: {details}{'...' if n > 5 else ''}")
        return "VERIFY_FAILED", f"Final verification failed. {n} lessons still show as pending."

# ----------------- CLI -----------------
def run_date_range_task(client: SeiueAPIClient, start_str: str, end_str: str):
    start_date = BEIJING_TZ.localize(datetime.strptime(start_str, "%Y%m%d"))
    end_date = BEIJING_TZ.localize(datetime.strptime(end_str, "%Y%m%d"))

    last_processed = _load_state()
    current_date = start_date

    if last_processed and start_date <= last_processed < end_date:
        current_date = last_processed + timedelta(days=1)
        logging.info(f"Resuming date range task from last processed date: {last_processed.strftime('%Y-%m-%d')}. Next date: {current_date.strftime('%Y-%m-%d')}")
    elif last_processed and last_processed >= end_date:
        logging.info("All dates in range already processed according to state file. Clearing state.")
        _clear_state()
        return
    elif start_date > end_date:
        logging.warning("Start date is after end date. No dates to process.")
        _clear_state()
        return

    results = defaultdict(list)
    TERMINAL = {"SUCCESS", "SUCCESS_WITH_WARNINGS", "NO_ACTION_NEEDED", "NO_CLASS", "NOTHING_TO_SUBMIT"}
    try:
        while current_date <= end_date:
            date_iso = current_date.strftime('%Y-%m-%d')
            logging.info(f"\n--- Processing Date: {date_iso} ---")
            status, message = process_day(client, current_date)
            log_summary(date_iso, status, message)
            results[status].append(date_iso)
            if status in TERMINAL:
                _save_state(current_date)
            else:
                logging.warning(f"State NOT saved for date {date_iso} (Status: {status}). This date may be retried on next run.")
            if current_date < end_date:
                time.sleep(random.uniform(2, 5))
            current_date += timedelta(days=1)
    except KeyboardInterrupt:
        logging.info("Date range task interrupted by user.")
        sys.exit(130)
    finally:
        logging.info("--- Date Range Task Finished ---")
        logging.info("--- FINAL SUMMARY REPORT ---")
        total_ok = len(results['SUCCESS']) + len(results['SUCCESS_WITH_WARNINGS'])
        logging.info(f"✅ Successfully Processed Days ({total_ok}): {', '.join(results['SUCCESS'] + results['SUCCESS_WITH_WARNINGS']) or 'None'}")
        logging.info(f"ℹ️ No Action Needed / Already Done ({len(results['NO_ACTION_NEEDED'])}): {', '.join(results['NO_ACTION_NEEDED']) or 'None'}")
        failed_count = sum(len(results[s]) for s in results if s not in TERMINAL and s not in ['SUCCESS', 'SUCCESS_WITH_WARNINGS'])
        logging.info(f"❌ Failures ({failed_count}):")
        if failed_count > 0:
            for status_key, dates in results.items():
                if status_key not in TERMINAL and status_key not in ['SUCCESS', 'SUCCESS_WITH_WARNINGS'] and dates:
                    logging.info(f"   - {status_key}: {', '.join(dates)}")
        else:
            logging.info("   None")
        _clear_state()

def main():
    try:
        today_cst = datetime.now(BEIJING_TZ).astimezone(BEIJING_TZ)
        print("\n--- Welcome to Seiue Auto Attendance Script (v1.0 - Robust Verification) ---")
        print(f"(Current Beijing Time: {today_cst.strftime('%Y-%m-%d %H:%M:%S %Z%z')})")
        if not SEIUE_USERNAME or not SEIUE_PASSWORD:
            print("\nError: SEIUE_USERNAME or SEIUE_PASSWORD environment variables are not set.")
            print("Please set them before running the script. Example: export SEIUE_USERNAME=\"your_username\"")
            sys.exit(1)

        print("\n[1] Run for today | [2] Run for a specific date | [3] Run for a date range")
        choice = input("Select mode [1/2/3]: ").strip()
        if choice not in ('1', '2', '3'):
            print("Invalid option. Exiting.")
            sys.exit(2)

        client = SeiueAPIClient(SEIUE_USERNAME, SEIUE_PASSWORD)
        if not client.login_and_get_token():
            print("\nError: Login failed. Please check credentials or network.")
            sys.exit(3)
        
        exit_code = 1
        if choice == '1':
            target_date = today_cst
            status, msg = process_day(client, target_date)
            log_summary(target_date.strftime("%Y-%m-%d"), status, msg)
            print(f"\nResult: {status}\nDetail: {msg}\n")
            if status in {"SUCCESS", "NO_CLASS", "NO_ACTION_NEEDED", "NOTHING_TO_SUBMIT"}:
                exit_code = 0
        elif choice == '2':
            date_str = input("Enter target date (YYYYMMDD): ").strip()
            try:
                target_date = datetime.strptime(date_str, "%Y%m%d").replace(tzinfo=pytz.timezone('Asia/Shanghai'))
            except ValueError:
                print("Bad date format. Expected YYYYMMDD.")
                sys.exit(2)
            status, msg = process_day(client, target_date)
            log_summary(target_date.strftime("%Y-%m-%d"), status, msg)
            print(f"\nResult: {status}\nDetail: {msg}\n")
            if status in {"SUCCESS", "NO_CLASS", "NO_ACTION_NEEDED", "NOTHING_TO_SUBMIT"}:
                exit_code = 0
        elif choice == '3':
            start_str = input("Enter start date (YYYYMMDD): ").strip()
            end_str = input("Enter end date (YYYYMMDD): ").strip()
            if datetime.strptime(start_str, "%Y%m%d") > datetime.strptime(end_str, "%Y%m%d"):
                raise ValueError("Start date cannot be after end date.")
            run_date_range_task(client, start_str, end_str)
            exit_code = 0

        print("\n--- Task Finished ---")
        sys.exit(exit_code)
    except ValueError as e:
        print(f"\nError: Invalid input. ({e})")
        sys.exit(1)
    except (KeyboardInterrupt, EOFError):
        print("\nOperation cancelled by user.")
        sys.exit(130)
    except Exception as e:
        logging.error(f"An unexpected error occurred: {e}", exc_info=True)
        sys.exit(1)

if __name__ == "__main__":
    main()
