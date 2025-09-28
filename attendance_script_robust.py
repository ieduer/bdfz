#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import re
import time
import logging
import os
from datetime import datetime
import pytz
from functools import wraps
import sys
import requests

from selenium import webdriver
from selenium.webdriver.chrome.service import Service
from selenium.webdriver.common.by import By
from selenium.webdriver.support.ui import WebDriverWait
from selenium.webdriver.support import expected_conditions as EC
from selenium.common.exceptions import (
    NoSuchElementException,
    TimeoutException,
    ElementClickInterceptedException,
    StaleElementReferenceException,
    WebDriverException,
    InvalidSessionIdException
)
from webdriver_manager.chrome import ChromeDriverManager

# --- 配置 ---
LOGIN_URL = "https://passport.seiue.com/login?school_id=3&type=account&from=null&redirect_url=null"
USERNAME = ""
PASSWORD = ""
LOG_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "attendance_final_v10.4.18_robust_interactive.log") # CHANGED V10.4.18
SCREENSHOT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "error_artifacts")
BEIJING_TZ = pytz.timezone('Asia/Shanghai')
MAX_RETRIES_ON_ERROR = 2
RETRY_DELAY = 5
PROCESS_TIMEOUT = 720
WAIT_TIMEOUT_LONGEST = 120
WAIT_TIMEOUT_LONG = 75
WAIT_TIMEOUT_MEDIUM = 40
WAIT_TIMEOUT_SHORT = 20
WAIT_TIMEOUT_VERY_SHORT = 10

os.makedirs(SCREENSHOT_DIR, exist_ok=True)
# --- 日誌配置 ---
root_logger = logging.getLogger()
for handler in root_logger.handlers[:]:
    root_logger.removeHandler(handler)
    handler.close()

logging.basicConfig(
    level=logging.DEBUG,
    format='%(asctime)s.%(msecs)03d - %(levelname)s - %(filename)s:%(lineno)d - %(message)s',
    datefmt='%Y-%m-%d %H:%M:%S',
    handlers=[
        logging.FileHandler(LOG_FILE, encoding='utf-8', mode='a'),
        logging.StreamHandler(sys.stdout)
    ]
)
logging.getLogger("WDM").setLevel(logging.WARNING)
logging.getLogger("selenium.webdriver.remote.remote_connection").setLevel(logging.WARNING)
logging.getLogger("urllib3.connectionpool").setLevel(logging.INFO)

# --- 輔助函數：保存 Artifacts ---
def save_error_artifacts(driver, error_type="error"):
    if not driver:
        logging.warning("Driver is None, 無法保存 artifacts。")
        return
    try:
        timestamp = datetime.now(BEIJING_TZ).strftime("%Y%m%d_%H%M%S_%f")[:-3]
        screenshot_path = os.path.join(SCREENSHOT_DIR, f"{error_type}_{timestamp}.png")
        page_source_path = os.path.join(SCREENSHOT_DIR, f"{error_type}_{timestamp}.html")

        current_url = "N/A (Session Invalid?)"
        page_source = "N/A (Session Invalid?)"
        try:
            current_url = driver.current_url
        except WebDriverException as url_err:
            logging.debug(f"保存 artifacts 時獲取 current_url 失敗 (可能 session 失效): {url_err}")
        try:
            page_source = driver.page_source
        except WebDriverException as src_err:
            logging.debug(f"保存 artifacts 時獲取 page_source 失敗 (可能 session 失效): {src_err}")

        try:
            driver.save_screenshot(screenshot_path)
            logging.info(f"錯誤截圖已保存到: {screenshot_path}")
        except WebDriverException as screen_err:
            logging.error(f"保存錯誤截圖失敗 (可能 Session 無效或驅動問題): {screen_err}")

        try:
            with open(page_source_path, 'w', encoding='utf-8') as f:
                f.write(f"<!-- URL at time of error: {current_url} -->\n")
                f.write(page_source)
            logging.info(f"錯誤頁面源碼已保存到: {page_source_path}")
        except Exception as generic_source_err:
            logging.error(f"保存錯誤頁面源碼時發生錯誤: {generic_source_err}")

    except InvalidSessionIdException:
        logging.warning("捕獲到 InvalidSessionIdException，無法保存 artifacts (Session 已失效)。")
    except WebDriverException as e:
        logging.error(f"保存 artifacts 時發生 WebDriver 異常: {e}")
    except Exception as e:
        logging.error(f"保存 artifacts 時發生未知錯誤: {e}")

# --- 重試裝飾器 ---
def retry_on_exception(retries=MAX_RETRIES_ON_ERROR, delay=RETRY_DELAY, exceptions=(TimeoutException, StaleElementReferenceException, ElementClickInterceptedException, WebDriverException)):
    def decorator(func):
        @wraps(func)
        def wrapper(*args, **kwargs_received_by_wrapper):
            attempts = 0
            outer_kwargs_ref = kwargs_received_by_wrapper.get('__outer_kwargs__')

            if outer_kwargs_ref is not None and isinstance(outer_kwargs_ref, dict):
                session_invalid_flag = outer_kwargs_ref.get('__session_invalid_flag__', False)
            else:
                session_invalid_flag = kwargs_received_by_wrapper.get('__session_invalid_flag__', False)
                outer_kwargs_ref = kwargs_received_by_wrapper

            kwargs_for_func_call = {}

            while attempts <= retries:
                try:
                    kwargs_for_func_call = kwargs_received_by_wrapper.copy()
                    kwargs_for_func_call['__session_invalid_flag__'] = session_invalid_flag

                    result = func(*args, **kwargs_for_func_call)

                    session_invalid_flag = kwargs_for_func_call.get('__session_invalid_flag__', session_invalid_flag)
                    return result
                except exceptions as e:
                    attempts += 1
                    session_invalid_flag = kwargs_for_func_call.get('__session_invalid_flag__', session_invalid_flag)

                    driver_instance = args[0] if args and isinstance(args[0], webdriver.Remote) else None
                    is_invalid_session = isinstance(e, InvalidSessionIdException) or \
                                         (isinstance(e, WebDriverException) and
                                          any(msg in str(e).lower() for msg in [
                                              "invalid session id", "session deleted",
                                              "chrome not reachable", "no such execution context",
                                              "target window already closed"
                                          ]))

                    if driver_instance and not is_invalid_session and not session_invalid_flag:
                        try:
                            _ = driver_instance.title
                        except InvalidSessionIdException:
                            is_invalid_session = True
                            session_invalid_flag = True
                            logging.warning(f"函數 {func.__name__} 重試前檢測到 Session 已失效 (InvalidSessionIdException during check)。")
                        except WebDriverException as wd_check_err:
                             if any(msg in str(wd_check_err).lower() for msg in [
                                     "invalid session id", "session deleted", "chrome not reachable",
                                     "no such execution context", "target window already closed"
                                 ]):
                                  is_invalid_session = True
                                  session_invalid_flag = True
                                  logging.warning(f"函數 {func.__name__} 重試前通過檢查操作檢測到 Session 已失效 ({wd_check_err})。")

                    if is_invalid_session or session_invalid_flag:
                         logging.error(f"函數 {func.__name__} 遇到 InvalidSessionIdException 或檢測到 Session 失效，不進行重試。錯誤: {type(e).__name__}")
                         if outer_kwargs_ref is not None and isinstance(outer_kwargs_ref, dict):
                            outer_kwargs_ref['__session_invalid_flag__'] = True
                         kwargs_received_by_wrapper['__session_invalid_flag__'] = True
                         raise e

                    if attempts > retries:
                         logging.error(f"函數 {func.__name__} 在 {attempts-1} 次重試後仍然失敗。最後錯誤: {type(e).__name__}: {e}")
                         current_session_flag_for_save = (outer_kwargs_ref.get('__session_invalid_flag__', False)
                                                          if outer_kwargs_ref and isinstance(outer_kwargs_ref, dict)
                                                          else kwargs_received_by_wrapper.get('__session_invalid_flag__', False))
                         if driver_instance and not current_session_flag_for_save:
                             save_error_artifacts(driver_instance, f"{func.__name__}_final_retry_fail")
                         raise e
                    else:
                         logging.warning(f"函數 {func.__name__} 遇到錯誤: {type(e).__name__}. 第 {attempts}/{retries} 次重試 (延遲 {delay * attempts} 秒)...")
                         current_session_flag_for_save_retry = (outer_kwargs_ref.get('__session_invalid_flag__', False)
                                                               if outer_kwargs_ref and isinstance(outer_kwargs_ref, dict)
                                                               else kwargs_received_by_wrapper.get('__session_invalid_flag__', False))
                         if driver_instance and not current_session_flag_for_save_retry:
                             save_error_artifacts(driver_instance, f"{func.__name__}_retry_{attempts}")
                         time.sleep(delay * attempts)
                finally:
                     if outer_kwargs_ref is not None and isinstance(outer_kwargs_ref, dict):
                          outer_kwargs_ref['__session_invalid_flag__'] = session_invalid_flag
                     else:
                          kwargs_received_by_wrapper['__session_invalid_flag__'] = session_invalid_flag
            return None
        return wrapper
    return decorator

# --- WebDriver 初始化 ---
@retry_on_exception(retries=2, delay=5, exceptions=(WebDriverException,))
def get_webdriver(**kwargs):
    options = webdriver.ChromeOptions()
    options.add_argument("--headless=new")
    options.add_argument("--window-size=1920,1080")
    options.add_argument("--no-sandbox")
    options.add_argument("--disable-dev-shm-usage")
    options.add_argument("--disable-extensions")
    options.add_argument("--disable-infobars")
    options.add_argument('--ignore-certificate-errors')
    options.add_argument('--allow-running-insecure-content')
    options.add_argument('--log-level=3')
    options.add_argument("user-agent=Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Safari/537.36")
    options.add_experimental_option("excludeSwitches", ["enable-automation", "enable-logging"])
    options.add_experimental_option('useAutomationExtension', False)
    options.add_argument('--disable-gpu')
    options.add_argument('--disable-blink-features=AutomationControlled')
    options.add_argument('--disable-popup-blocking')
    options.add_argument("--disable-background-networking")
    options.add_argument("--disable-background-timer-throttling")
    options.add_argument("--disable-backgrounding-occluded-windows")
    options.add_argument("--disable-breakpad")
    options.add_argument("--disable-client-side-phishing-detection")
    options.add_argument("--disable-component-update")
    options.add_argument("--disable-default-apps")
    options.add_argument("--disable-domain-reliability")
    options.add_argument("--disable-features=AudioServiceOutOfProcess,IsolateOrigins,site-per-process")
    options.add_argument("--disable-hang-monitor")
    options.add_argument("--disable-ipc-flooding-protection")
    options.add_argument("--disable-notifications")
    options.add_argument("--disable-offer-store-unmasked-wallet-cards")
    options.add_argument("--disable-print-preview")
    options.add_argument("--disable-prompt-on-repost")
    options.add_argument("--disable-renderer-backgrounding")
    options.add_argument("--disable-setuid-sandbox")
    options.add_argument("--disable-speech-api")
    options.add_argument("--disable-sync")
    options.add_argument("--disk-cache-size=33554432")
    options.add_argument("--force-color-profile=srgb")
    options.add_argument("--metrics-recording-only")
    options.add_argument("--mute-audio")
    options.add_argument("--no-default-browser-check")
    options.add_argument("--no-first-run")
    options.add_argument("--password-store=basic")
    options.add_argument("--use-mock-keychain")
    options.add_argument("--enable-features=NetworkService,NetworkServiceInProcess")
    options.add_argument("--disable-features=VizDisplayCompositor")

    driver_path = None
    try:
        logging.info("使用 webdriver-manager 初始化 ChromeDriver...")
        retries_wdm = 3
        for attempt in range(retries_wdm):
            try:
                driver_path = ChromeDriverManager().install()
                logging.info(f"ChromeDriver 路徑: {driver_path}")
                break
            except requests.exceptions.RequestException as conn_err:
                 logging.warning(f"webdriver-manager 連接失敗 (嘗試 {attempt + 1}/{retries_wdm}): {conn_err}")
                 if attempt == retries_wdm - 1:
                     logging.error("webdriver-manager 連接最終失敗。")
                     raise WebDriverException(f"webdriver-manager connection failed: {conn_err}")
                 time.sleep(5 * (attempt + 1))
            except Exception as install_err:
                 logging.error(f"webdriver-manager 初始化或安裝時出錯 (嘗試 {attempt + 1}/{retries_wdm}): {install_err}", exc_info=False)
                 if attempt == retries_wdm - 1:
                     raise WebDriverException(f"webdriver-manager install failed: {install_err}")
                 time.sleep(5 * (attempt + 1))
        if not driver_path:
             raise WebDriverException("無法通過 webdriver-manager 安裝或找到 ChromeDriver")
    except Exception as manager_err:
        logging.error(f"webdriver-manager 處理過程中出錯: {manager_err}", exc_info=True)
        raise

    try:
        service = Service(driver_path)
        driver = webdriver.Chrome(service=service, options=options)
        logging.info("Headless WebDriver 初始化成功。")
        driver.implicitly_wait(0)
        driver.set_page_load_timeout(WAIT_TIMEOUT_LONGEST)
        driver.set_script_timeout(WAIT_TIMEOUT_LONG)
        return driver
    except WebDriverException as wd_err:
        logging.error(f"啟動 WebDriver 失敗: {wd_err}", exc_info=True)
        if "invalid session id" in str(wd_err).lower() or "session deleted" in str(wd_err).lower() or "chrome not reachable" in str(wd_err).lower():
             kwargs['__session_invalid_flag__'] = True
        raise
    except Exception as e:
        logging.error(f"WebDriver 初始化過程中發生未知錯誤: {e}", exc_info=True)
        raise

# --- 登錄 ---
@retry_on_exception(retries=2, delay=10, exceptions=(TimeoutException, WebDriverException))
def login(driver, url, username, password, **kwargs_of_login):
    logging.info(f"訪問登錄頁面: {url}")
    try:
        driver.get(url)
    except TimeoutException:
        page_load_timeout_val = 'N/A'
        try: page_load_timeout_val = driver.timeouts.page_load / 1000
        except: pass
        logging.error(f"訪問登錄頁面超時 ({page_load_timeout_val}s): {url}")
        if driver and not kwargs_of_login.get('__session_invalid_flag__', False): save_error_artifacts(driver, "login_page_load_timeout")
        raise
    except WebDriverException as e:
        if "invalid session id" in str(e).lower() or "session deleted" in str(e).lower() or "chrome not reachable" in str(e).lower():
             kwargs_of_login['__session_invalid_flag__'] = True
        logging.error(f"訪問登錄頁面時發生 WebDriver 異常: {e}", exc_info=True)
        if driver and not kwargs_of_login.get('__session_invalid_flag__', False): save_error_artifacts(driver, "login_page_load_error")
        raise

    try:
        login_page_marker_xpath = "//*[@id='usin'] | //div[contains(@class, 'login-header-main') and contains(text(), '账号登录')] | //button[@e2e-id='submit']"
        login_page_marker = (By.XPATH, login_page_marker_xpath)
        logging.info("等待登錄頁面標誌性元素加載...")
        WebDriverWait(driver, WAIT_TIMEOUT_LONG).until(
            EC.visibility_of_element_located(login_page_marker)
        )
        logging.info("登錄頁面基本元素已加載。")
        time.sleep(0.5 + time.time() % 0.5)

        wait = WebDriverWait(driver, WAIT_TIMEOUT_MEDIUM)
        user_field = wait.until(EC.visibility_of_element_located((By.ID, "usin")), "定位用戶名輸入框 (#usin)")
        pass_field = wait.until(EC.visibility_of_element_located((By.ID, "password")), "定位密碼輸入框 (#password)")
        login_button_locator = (By.CSS_SELECTOR, "button[e2e-id='submit']")

        logging.info("輸入用戶名...")
        user_field.clear(); time.sleep(0.2 + time.time() % 0.1)
        user_field.send_keys(username); time.sleep(0.2 + time.time() % 0.1)
        logging.info("輸入密碼...")
        pass_field.clear(); time.sleep(0.2 + time.time() % 0.1)
        pass_field.send_keys(password); time.sleep(0.2 + time.time() % 0.1)

        @retry_on_exception(retries=1, delay=2, exceptions=(TimeoutException, ElementClickInterceptedException, StaleElementReferenceException))
        def click_login_button_with_retry(button_locator_for_retry, **inner_kwargs_click_login):
             logging.info("嘗試點擊登錄按鈕...")
             button_to_click_now = None
             try:
                 button_to_click_now = WebDriverWait(driver, WAIT_TIMEOUT_SHORT).until(EC.element_to_be_clickable(button_locator_for_retry))
                 driver.execute_script("arguments[0].scrollIntoViewIfNeeded(true);", button_to_click_now)
                 time.sleep(0.3 + time.time() % 0.2)
                 driver.execute_script("arguments[0].click();", button_to_click_now)
                 logging.info("使用 JS 點擊登錄按鈕")
             except WebDriverException as js_click_err:
                  if "invalid session id" in str(js_click_err).lower() or "session deleted" in str(js_click_err).lower() or "chrome not reachable" in str(js_click_err).lower():
                      if inner_kwargs_click_login.get('__outer_kwargs__'):
                          inner_kwargs_click_login['__outer_kwargs__']['__session_invalid_flag__'] = True
                      else:
                          inner_kwargs_click_login['__session_invalid_flag__'] = True
                      raise
                  logging.warning(f"JS 點擊失敗 ({type(js_click_err).__name__}), 嘗試普通點擊...")
                  try:
                      if button_to_click_now is None:
                          button_to_click_now = WebDriverWait(driver, WAIT_TIMEOUT_SHORT).until(EC.element_to_be_clickable(button_locator_for_retry))
                      driver.execute_script("arguments[0].scrollIntoViewIfNeeded(true);", button_to_click_now)
                      time.sleep(0.2 + time.time() % 0.1)
                      button_to_click_now.click()
                      logging.info("使用普通 click() 點擊登錄按鈕")
                  except WebDriverException as normal_click_err:
                      if "invalid session id" in str(normal_click_err).lower() or "session deleted" in str(normal_click_err).lower() or "chrome not reachable" in str(normal_click_err).lower():
                           if inner_kwargs_click_login.get('__outer_kwargs__'):
                                inner_kwargs_click_login['__outer_kwargs__']['__session_invalid_flag__'] = True
                           else:
                               inner_kwargs_click_login['__session_invalid_flag__'] = True
                           raise
                      raise
                  except Exception as normal_click_err_general:
                      raise normal_click_err_general
             except Exception as click_err:
                  raise click_err

        effective_kwargs_for_click_retry = {}
        for key, value in kwargs_of_login.items():
            if key != '__outer_kwargs__':
                effective_kwargs_for_click_retry[key] = value
        effective_kwargs_for_click_retry['__outer_kwargs__'] = kwargs_of_login

        click_login_button_with_retry(login_button_locator, **effective_kwargs_for_click_retry)

        if kwargs_of_login.get('__session_invalid_flag__', False):
            raise InvalidSessionIdException("Session invalid during login button click (propagated from inner call)")

        logging.info("等待登錄後頁面跳轉...")
        try:
            WebDriverWait(driver, WAIT_TIMEOUT_LONGEST).until(
                EC.any_of(
                    EC.url_contains('binding'),
                    EC.url_contains('chalk-c3'),
                    EC.url_matches(r'https:\/\/[^/]+\/(?:$|home|dashboard|schedule)'),
                    EC.visibility_of_element_located((By.XPATH, "//span[contains(text(),'工作台')] | //div[contains(@class, 'seiue-schedule-container')] | //div[@id='export-class']"))
                )
            )
            current_url = driver.current_url
            logging.info(f"登錄成功或進入下一步，當前 URL: {current_url}")
            return True
        except TimeoutException:
             logging.error(f"登錄後等待跳轉或關鍵元素超時({WAIT_TIMEOUT_LONGEST}s)。")
             if driver and not kwargs_of_login.get('__session_invalid_flag__', False): save_error_artifacts(driver, "login_redirect_timeout")
             error_msg = "未知登錄錯誤"
             try:
                 error_elements_locators = [
                     (By.XPATH, "//*[contains(@class, 'form-error-message')]"),
                     (By.XPATH, "//*[contains(@class, 'ant-form-item-explain-error')]"),
                     (By.XPATH, "//*[contains(text(), '用户名或密码错误')]"),
                     (By.XPATH, "//*[contains(text(), '登录失败')]")
                 ]
                 for loc in error_elements_locators:
                     try:
                        error_element = WebDriverWait(driver, 2).until(EC.visibility_of_element_located(loc))
                        if error_element and error_element.text.strip():
                            error_msg = error_element.text.strip()
                            logging.error(f"檢測到登錄錯誤提示: {error_msg}")
                            break
                     except:
                        pass
             except Exception: pass
             raise TimeoutException(f"登錄後跳轉超時。檢測到的錯誤: {error_msg}")

    except (TimeoutException, NoSuchElementException, ElementClickInterceptedException) as e:
        logging.error(f"登錄過程中定位或交互元素失敗: {type(e).__name__} - {e}", exc_info=False)
        if driver and not kwargs_of_login.get('__session_invalid_flag__', False): save_error_artifacts(driver, f"login_element_fail_{type(e).__name__}")
        raise
    except InvalidSessionIdException:
        logging.error("登錄過程中 Session 失效。", exc_info=False)
        kwargs_of_login['__session_invalid_flag__'] = True
        raise
    except WebDriverException as e:
         if "invalid session id" in str(e).lower() or "session deleted" in str(e).lower() or "chrome not reachable" in str(e).lower():
              kwargs_of_login['__session_invalid_flag__'] = True
         logging.error(f"登錄過程中發生 WebDriver 異常: {e}", exc_info=True)
         if driver and not kwargs_of_login.get('__session_invalid_flag__', False): save_error_artifacts(driver, "login_webdriver_error")
         raise
    except Exception as e:
        logging.error(f"登錄過程中發生未預期異常: {e}", exc_info=True)
        if driver and not kwargs_of_login.get('__session_invalid_flag__', False): save_error_artifacts(driver, "login_unexpected_error")
        raise

# --- 跳過綁定 ---
@retry_on_exception(retries=1, delay=3)
def skip_phone_binding(driver, **kwargs):
    time.sleep(1 + time.time() % 1.0)
    try:
        current_url = driver.current_url
    except WebDriverException as e:
        if "invalid session id" in str(e).lower() or "session deleted" in str(e).lower() or "chrome not reachable" in str(e).lower():
             kwargs['__session_invalid_flag__'] = True
             logging.error("檢查綁定頁面 URL 時 Session 失效。", exc_info=False)
             raise InvalidSessionIdException("Session invalid checking binding URL")
        else:
            logging.error(f"檢查綁定頁面 URL 時發生 WebDriver 異常: {e}", exc_info=True)
            return True

    logging.debug(f"檢查是否在綁定頁面，當前 URL: {current_url}")

    if 'binding' not in current_url.lower():
        logging.info("當前不在綁定頁面，跳過處理。")
        return True

    logging.info("檢測到可能在綁定手機頁面，嘗試處理...")
    try:
        wait = WebDriverWait(driver, WAIT_TIMEOUT_MEDIUM)
        skip_button_locator = (By.XPATH, "//div[contains(@class, 'binding-phone-custom-btn') and normalize-space(.)='跳过'] | //div[contains(@class, 'skip-btn') and normalize-space(.)='跳过']")
        logging.info("嘗試定位'跳過'按鈕...")
        skip_button = wait.until(EC.element_to_be_clickable(skip_button_locator))
        logging.info("成功定位'跳過'按鈕，嘗試點擊...")

        driver.execute_script("arguments[0].scrollIntoViewIfNeeded(true);", skip_button); time.sleep(0.3 + time.time() % 0.2)
        driver.execute_script("arguments[0].click();", skip_button)
        logging.info("已點擊'跳過'按鈕。")

        WebDriverWait(driver, WAIT_TIMEOUT_LONG).until(
            EC.any_of(
                EC.url_contains('chalk-c3'),
                EC.url_matches(r'https:\/\/[^/]+\/(?:$|home|dashboard|schedule)'),
                EC.visibility_of_element_located((By.XPATH, "//span[contains(text(),'工作台')] | //div[contains(@class, 'seiue-schedule-container')] | //div[@id='export-class']"))
            )
        )
        logging.info(f"已點擊'跳過'並跳轉到目標頁面，當前 URL: {driver.current_url}")
        time.sleep(1.5 + time.time() % 1.0)
        return True
    except TimeoutException:
        logging.warning("等待'跳過'按鈕或跳轉超時。可能實際不在綁定頁面、已自動跳過或頁面加載問題。")
        try:
            current_url_after_timeout = driver.current_url
            if 'binding' not in current_url_after_timeout.lower() and \
               ('chalk-c3' in current_url_after_timeout or \
               any(keyword in current_url_after_timeout for keyword in ['home', 'dashboard', 'schedule'])):
                logging.info(f"雖然跳轉等待超時，但當前 URL ({current_url_after_timeout}) 看似已是目標頁面。")
                return True
            else:
                logging.warning(f"跳轉超時後，URL ({current_url_after_timeout}) 仍可能在綁定頁面或未知頁面。")
        except WebDriverException:
             pass
        if driver and not kwargs.get('__session_invalid_flag__', False): save_error_artifacts(driver, "skip_binding_redirect_timeout")
        return True
    except InvalidSessionIdException:
        logging.error("跳過綁定時 Session 失效。", exc_info=False)
        kwargs['__session_invalid_flag__'] = True
        raise
    except WebDriverException as e:
         if "invalid session id" in str(e).lower() or "session deleted" in str(e).lower() or "chrome not reachable" in str(e).lower():
              kwargs['__session_invalid_flag__'] = True
         logging.error(f"處理綁定手機頁面時發生 WebDriver 異常: {e}", exc_info=True)
         if driver and not kwargs.get('__session_invalid_flag__', False): save_error_artifacts(driver, "skip_binding_webdriver_error")
         return True
    except Exception as e:
        logging.error(f"處理綁定手機頁面時出錯: {e}", exc_info=True)
        if driver and not kwargs.get('__session_invalid_flag__', False): save_error_artifacts(driver, "skip_binding_failed")
        return True

# CHANGED V10.4.18: Updated helper function
def is_button_in_valid_card(driver, button_element):
    """
    Checks if the given button element is inside a recognizable course card structure.
    A valid card is assumed to be an ancestor div that contains an h3 element (course title)
    and a span with a time-like pattern (HH:MM).
    """
    try:
        # A more robust check: a valid card's ancestor has both a title (h3) and a time string.
        # This helps differentiate from other UI elements that might accidentally have an h3.
        # The time regex looks for patterns like "08:00" or "15:40".
        ancestor_xpath = "./ancestor::div[.//h3 and .//span[contains(text(), ':') and string-length(substring-before(text(), ':')) > 0 and string-length(substring-after(text(), ':')) > 0]]"
        ancestor_card_like_div = button_element.find_element(By.XPATH, ancestor_xpath)
        
        if ancestor_card_like_div and button_element.is_displayed():
            logging.debug(f"Button '{button_element.text}' is in a valid card structure (ancestor with h3 and time span).")
            return True
    except NoSuchElementException:
        pass # It's okay if it's not found, we'll return False.
    except Exception as e:
        logging.warning(f"Error checking if button is in valid card: {e}")
    
    # Fallback to just checking for h3 if the more specific check fails
    try:
        ancestor_card_like_div = button_element.find_element(By.XPATH, "./ancestor::div[.//h3][1]")
        if ancestor_card_like_div and button_element.is_displayed():
            logging.debug(f"Button '{button_element.text}' is in a div with an h3 (fallback check passed).")
            return True
        else:
             return False # Found an ancestor with h3, but the button itself is not displayed.
    except NoSuchElementException:
        logging.debug(f"Button '{button_element.text}' does not seem to be in a course card (no ancestor div with h3 found).")
    except Exception as e:
        logging.warning(f"Error during fallback check for button in valid card: {e}")
        
    return False

# --- 處理考勤 ---
def process_attendance(driver, **kwargs):
    start_process_time = time.time()
    logging.info("開始處理考勤流程...")

    schedule_container_locator = (By.ID, "export-class")

    record_text = "录入考勤"
    modify_text = "修改考勤"
    submit_attendance_text = "提交考勤"
    modify_attendance_text_modal = "修改考勤"

    calendar_context_xpath = "//div[@id='export-class']"
    
    # CHANGED V10.4.18: Using broad locators to be filtered later
    record_buttons_locator_broad = (By.XPATH, f"{calendar_context_xpath}//div[normalize-space(.)='{record_text}']")
    modify_buttons_locator_broad = (By.XPATH, f"{calendar_context_xpath}//div[normalize-space(.)='{modify_text}']")
    
    # CHANGED V10.4.18: A very generic locator for any div that looks like a card (has an h3).
    has_visible_course_card_locator = (By.XPATH, f"{calendar_context_xpath}//div[.//h3[normalize-space(.)!='']]")
    logging.debug(f"Defined has_visible_course_card_locator: {has_visible_course_card_locator[1]}")
    
    generic_ancestor_with_h3_xpath = "./ancestor::div[.//h3][1]"
    logging.debug(f"Defined generic_ancestor_with_h3_xpath: {generic_ancestor_with_h3_xpath}")

    try:
        logging.info(f"等待課表容器加載 (最長 {WAIT_TIMEOUT_LONG} 秒)...")
        schedule_container = WebDriverWait(driver, WAIT_TIMEOUT_LONG).until(
            EC.presence_of_element_located(schedule_container_locator)
        )
        logging.info("課表容器元素 (id='export-class') 已存在。")
        time.sleep(0.5 + time.time() % 0.5)
        logging.info("嘗試將課表容器滾動到視圖中間...")
        try:
             driver.execute_script("arguments[0].scrollIntoView({behavior: 'auto', block: 'center', inline: 'center'});", schedule_container)
             time.sleep(1 + time.time() % 0.5)
             logging.info("已執行滾動操作。")
        except Exception as scroll_err:
             logging.warning(f"滾動課表容器時出錯: {scroll_err}，繼續嘗試...")
    except TimeoutException:
        logging.error(f"等待課表容器元素 (id='export-class') 存在超時 ({WAIT_TIMEOUT_LONG}s)。無法繼續處理考勤。")
        if driver and not kwargs.get('__session_invalid_flag__', False): save_error_artifacts(driver, "schedule_container_timeout")
        raise TimeoutException(f"課表容器未在 {WAIT_TIMEOUT_LONG}s 內加載。")
    except InvalidSessionIdException:
        logging.error("等待課表容器時 Session 失效。", exc_info=False); kwargs['__session_invalid_flag__'] = True; raise
    except WebDriverException as e:
         if "invalid session id" in str(e).lower() or "session deleted" in str(e).lower() or "chrome not reachable" in str(e).lower():
              kwargs['__session_invalid_flag__'] = True
         logging.error(f"定位或滾動課表容器時發生 WebDriver 異常: {e}", exc_info=True)
         if driver and not kwargs.get('__session_invalid_flag__', False): save_error_artifacts(driver, "schedule_container_webdriver_error")
         raise
    except Exception as initial_err:
        logging.error(f"定位或滾動課表容器時發生錯誤: {initial_err}", exc_info=True)
        if driver and not kwargs.get('__session_invalid_flag__', False): save_error_artifacts(driver, "schedule_container_error")
        raise

    logging.info(f"開始嚴格狀態判斷：查找 '{record_text}' 按鈕 (日曆区域)...")
    visible_record_buttons = []
    try:
        logging.debug(f"Attempting to find record buttons with broad XPath: {record_buttons_locator_broad[1]}")
        candidate_record_buttons = WebDriverWait(driver, WAIT_TIMEOUT_MEDIUM).until(
            EC.presence_of_all_elements_located(record_buttons_locator_broad)
        )
        
        valid_candidate_buttons = []
        if candidate_record_buttons:
            logging.debug(f"找到 {len(candidate_record_buttons)} 個 '{record_text}' 文本匹配的候選元素，開始過濾...")
            for btn in candidate_record_buttons:
                if is_button_in_valid_card(driver, btn):
                    valid_candidate_buttons.append(btn)
            logging.debug(f"過濾後有效 '{record_text}' 按鈕 {len(valid_candidate_buttons)} 個。")
        visible_record_buttons = valid_candidate_buttons

    except TimeoutException:
        logging.info(f"在 {WAIT_TIMEOUT_MEDIUM}s 內未找到 '{record_text}' 的 presence (日曆区域，使用寬泛文本定位器)。")
    except InvalidSessionIdException: logging.error(f"查找 '{record_text}' 按鈕時 Session 失效。", exc_info=False); kwargs['__session_invalid_flag__'] = True; raise
    except WebDriverException as e:
         if "invalid session id" in str(e).lower() or "session deleted" in str(e).lower() or "chrome not reachable" in str(e).lower():
            kwargs['__session_invalid_flag__'] = True; raise
         else:
            logging.warning(f"查找 '{record_text}' 按鈕時 WebDriver 異常: {e}")

    if visible_record_buttons:
        logging.info(f"狀態確認：找到 {len(visible_record_buttons)} 個可見的、在课程卡片内的 '{record_text}' 按鈕。開始處理...")
    else:
        logging.info(f"未在日曆區域找到有效的 '{record_text}' 按鈕。檢查 '{modify_text}' 按鈕...")
        visible_modify_buttons = []
        try:
            logging.debug(f"Attempting to find modify buttons with broad XPath: {modify_buttons_locator_broad[1]}")
            candidate_modify_buttons = WebDriverWait(driver, WAIT_TIMEOUT_VERY_SHORT).until(
                EC.presence_of_all_elements_located(modify_buttons_locator_broad)
            )
            valid_candidate_modify_buttons = []
            if candidate_modify_buttons:
                logging.debug(f"找到 {len(candidate_modify_buttons)} 個 '{modify_text}' 文本匹配的候選元素，開始過濾...")
                for btn in candidate_modify_buttons:
                    if is_button_in_valid_card(driver, btn):
                         valid_candidate_modify_buttons.append(btn)
                logging.debug(f"過濾後有效 '{modify_text}' 按鈕 {len(valid_candidate_modify_buttons)} 個。")
            visible_modify_buttons = valid_candidate_modify_buttons
        except TimeoutException:
            logging.debug(f"在 {WAIT_TIMEOUT_VERY_SHORT}s 內未找到 '{modify_text}' 的 presence (日曆區域，使用寬泛文本定位器)。")
        except InvalidSessionIdException: logging.error(f"查找 '{modify_text}' 按鈕時 Session 失效。", exc_info=False); kwargs['__session_invalid_flag__'] = True; raise
        except WebDriverException as e:
            if "invalid session id" in str(e).lower() or "session deleted" in str(e).lower() or "chrome not reachable" in str(e).lower():
                kwargs['__session_invalid_flag__'] = True; raise
            else:
                logging.warning(f"查找 '{modify_text}' 按鈕時 WebDriver 異常: {e}")

        if visible_modify_buttons:
            logging.info(f"狀態確認：未找到 '录入考勤'，但找到 {len(visible_modify_buttons)} 個可見的 '{modify_text}' 按鈕 (在课程卡片内)。認為今日考勤已完成或無需錄入。")
            return "already_done"
        else:
            logging.info(f"未在日曆區域找到有效的 '{record_text}' 或 '{modify_text}' 按鈕。檢查日曆是否真的没有课程...")
            calendar_has_visible_courses = False
            try:
                WebDriverWait(driver, WAIT_TIMEOUT_VERY_SHORT).until(
                    EC.visibility_of_element_located(has_visible_course_card_locator)
                )
                calendar_has_visible_courses = True
                logging.info("找到至少一张可见的课程卡片 (匹配 has_visible_course_card_locator)。")
            except TimeoutException:
                logging.info(f"在 {WAIT_TIMEOUT_VERY_SHORT}s 内未找到可见的课程卡片 (has_visible_course_card_locator 未匹配)。")
                calendar_has_visible_courses = False
            except Exception as e:
                logging.error(f"检查日历课程卡片时遇到异常: {e}", exc_info=True)
                if driver and not kwargs.get('__session_invalid_flag__', False): save_error_artifacts(driver, "has_visible_card_check_error")
                return "failure_exception_has_card" # Critical failure

            if not calendar_has_visible_courses:
                logging.info("狀態確認：日曆区域未找到可见的课程卡片。认为日历为空或无课。")
                return "calendar_empty_but_verify_needed"
            else:
                logging.warning("狀態確認：日曆区域似乎存在可见的课程卡片，但未找到有效的 '录入考勤' 或 '修改考勤' 按鈕。页面状态可能异常。")
                return "calendar_has_cards_no_buttons_verify_needed"

    processed_successfully_count = 0
    buttons_to_process_count = len(visible_record_buttons)
    logging.info(f"檢測到 {buttons_to_process_count} 個有效待處理考勤 (日曆区域)，進入處理循環...")

    if buttons_to_process_count == 0:
        logging.info("循環開始前未發現有效 '录入考勤' 按鈕。")
        return "no_action_needed_before_loop"

    # Iterate a number of times equal to the buttons initially found.
    # On each iteration, re-find the list and process the first one.
    for i in range(buttons_to_process_count):
        if time.time() - start_process_time > PROCESS_TIMEOUT:
            logging.error(f"處理考勤步驟超時（超過 {PROCESS_TIMEOUT} 秒）。")
            if driver and not kwargs.get('__session_invalid_flag__', False): save_error_artifacts(driver, "process_attendance_timeout")
            raise TimeoutException("處理考勤步驟超時")
        
        try:
            _ = driver.current_url
        except WebDriverException as e:
            if "invalid session id" in str(e).lower() or "session deleted" in str(e).lower() or "chrome not reachable" in str(e).lower():
                kwargs['__session_invalid_flag__'] = True; raise
            logging.warning(f"處理循環中檢查 URL 出錯: {e}")

        button_to_click_this_iteration = None
        try:
            current_valid_buttons = []
            candidate_buttons = WebDriverWait(driver, WAIT_TIMEOUT_MEDIUM).until(
                EC.presence_of_all_elements_located(record_buttons_locator_broad)
            )
            for btn in candidate_buttons:
                if is_button_in_valid_card(driver, btn) and WebDriverWait(driver, 1).until(EC.element_to_be_clickable(btn)):
                    current_valid_buttons.append(btn)
            
            if not current_valid_buttons:
                logging.info(f"在第 {i+1} 次迭代中未找到更多可點擊的有效 '{record_text}' 按鈕。可能已全部處理完畢。")
                break # All done or buttons disappeared
            
            button_to_click_this_iteration = current_valid_buttons[0]
            logging.info(f"找到下一個有效待處理按鈕 (已處理 {processed_successfully_count} / 迭代 {i+1})。")
        except TimeoutException:
            logging.info(f"查找下一個有效 '{record_text}' 按鈕超時 (迭代 {i+1})。已處理 {processed_successfully_count}。"); break
        except Exception as find_err:
             logging.error(f"查找下一個有效按鈕時未知錯誤 (迭代 {i+1}): {find_err}", exc_info=True)
             if driver and not kwargs.get('__session_invalid_flag__', False): save_error_artifacts(driver, f"find_next_valid_button_error_iter_{i+1}")
             break

        course_name_for_log = f"課程 {processed_successfully_count + 1}"
        try:
            course_card_wrapper = WebDriverWait(button_to_click_this_iteration, WAIT_TIMEOUT_VERY_SHORT).until(
                EC.presence_of_element_located((By.XPATH, generic_ancestor_with_h3_xpath))
            )
            title_element = course_card_wrapper.find_element(By.XPATH, ".//h3")
            details_element = course_card_wrapper.find_element(By.XPATH, ".//span[contains(text(), ':')]")
            course_name_text = title_element.text.strip() if title_element and title_element.text else ""
            details_text_final = details_element.text.strip() if details_element and details_element.text else ""
            if course_name_text or details_text_final:
                 course_name_for_log = f"{course_name_text} ({details_text_final})".strip().replace("()","").replace("( )","")
        except Exception as e:
            logging.warning(f"提取课程信息失败: {e}")

        logging.info(f"準備處理課程: {course_name_for_log}")
        
        # ... Modal processing logic here, using button_to_click_this_iteration ...
        # (This part is copied and adapted from V10.4.9)
        click_success = False
        try:
            btn_to_click_refreshed = WebDriverWait(driver, WAIT_TIMEOUT_SHORT).until(EC.element_to_be_clickable(button_to_click_this_iteration))
            driver.execute_script("arguments[0].scrollIntoView({behavior: 'auto', block: 'center'});", btn_to_click_refreshed); time.sleep(0.7 + time.time()%0.3)
            logging.info(f"嘗試點擊 '{course_name_for_log}' 的 '{record_text}' 按鈕...")
            driver.execute_script("arguments[0].click();", btn_to_click_refreshed); click_success = True
            logging.info(f"成功點擊 '{course_name_for_log}' 按鈕。");
        except Exception as e_click:
            logging.error(f"點擊按鈕時發生嚴重錯誤，跳過此課程: {e_click}")
            continue

        modal_processed = False
        if click_success:
            # ... (Modal processing logic from V10.4.9) ...
            logging.info(f"'{record_text}' 按鈕已點擊，等待模態框加載 (最長 {WAIT_TIMEOUT_LONG} 秒)...")
            time.sleep(2 + time.time()%1.0)
            if driver and not kwargs.get('__session_invalid_flag__', False):
                 save_error_artifacts(driver, f"debug_modal_after_click_record_btn_{processed_successfully_count+1}")
                 logging.info("已保存點擊'录入考勤'後的截圖和源碼，用於分析模態框。")

            MODAL_ROOT_VISIBLE_XPATH = "//div[@class='ant-modal-root' and not(contains(@style,'display: none'))][last()]"
            MODAL_CONTENT_LOCATOR = (By.XPATH, f"{MODAL_ROOT_VISIBLE_XPATH}//div[@class='ant-modal-content']")
            MODAL_TITLE_SUBMIT_XPATH = f"{MODAL_ROOT_VISIBLE_XPATH}//div[contains(@class, 'se-modal__header-title') and normalize-space(text())='{submit_attendance_text}']"
            MODAL_TITLE_MODIFY_XPATH = f"{MODAL_ROOT_VISIBLE_XPATH}//div[contains(@class, 'se-modal__header-title') and normalize-space(text())='{modify_attendance_text_modal}']"
            MODAL_BATCH_SETTING_BUTTON_LOCATOR = (By.XPATH, f"{MODAL_ROOT_VISIBLE_XPATH}//button[@data-test-id='批量设置考勤按钮']")
            MODAL_SUBMIT_ATTENDANCE_BUTTON_LOCATOR = (By.XPATH, f"{MODAL_ROOT_VISIBLE_XPATH}//div[contains(@class, 'se-modal__footer')]//button[contains(@class, 'se-button__primary') and .//span[normalize-space()='{submit_attendance_text}']]")
            MODAL_MODIFY_ATTENDANCE_CONFIRM_BUTTON_LOCATOR = (By.XPATH, f"{MODAL_ROOT_VISIBLE_XPATH}//div[contains(@class, 'se-modal__footer')]//button[contains(@class, 'se-button__primary') and .//span[normalize-space()='{modify_attendance_text_modal}']]")
            MODAL_CANCEL_BUTTON_LOCATOR = (By.XPATH, f"{MODAL_ROOT_VISIBLE_XPATH}//div[contains(@class, 'se-modal__footer')]//button[not(contains(@class, 'se-button__primary')) and (.//span[normalize-space()='取消'] or .//span[normalize-space()='关闭'])]")
            MODAL_CLOSE_X_BUTTON_LOCATOR = (By.XPATH, f"{MODAL_ROOT_VISIBLE_XPATH}//button[@data-test-id='close-modal']")
            MODAL_BATCH_ALL_PRESENT_LOCATOR = (By.XPATH, "//div[contains(@class, 'ant-dropdown') and not(contains(@class, 'ant-dropdown-hidden'))]//ul//li[.//span[normalize-space()='全部出勤']]")
            MODAL_JOINT_SESSION_RADIO_LOCATOR = (By.XPATH, f"{MODAL_ROOT_VISIBLE_XPATH}//label[.//span[normalize-space()='连堂考勤']]//input[@type='radio']")

            try:
                logging.info(f"等待 '{course_name_for_log}' 模態框內容出現...")
                WebDriverWait(driver, WAIT_TIMEOUT_MEDIUM).until(EC.visibility_of_element_located(MODAL_CONTENT_LOCATOR))
                logging.info(f"'{course_name_for_log}' 的考勤模態框內容已出現。")
                time.sleep(1 + time.time()%0.5)

                # NEW V10.4.18: Handle joint session radio button
                try:
                    joint_session_radio = WebDriverWait(driver, WAIT_TIMEOUT_VERY_SHORT).until(EC.presence_of_element_located(MODAL_JOINT_SESSION_RADIO_LOCATOR))
                    if not joint_session_radio.is_selected():
                        logging.info("检测到连堂/分堂考勤选项，且'连堂考勤'未被选中。尝试点击'连堂考勤'。")
                        # Click the label associated with the radio for better stability
                        joint_session_label = joint_session_radio.find_element(By.XPATH, "./ancestor::label[1]")
                        driver.execute_script("arguments[0].click();", joint_session_label)
                        time.sleep(0.5)
                except TimeoutException:
                    logging.debug("未找到'连堂考勤'选项，按标准流程继续。")
                except Exception as e_joint_session:
                    logging.warning(f"处理'连堂考勤'选项时出错: {e_joint_session}")

                # Proceed with batch setting
                try:
                   batch_setting_button = WebDriverWait(driver, WAIT_TIMEOUT_MEDIUM).until(EC.element_to_be_clickable(MODAL_BATCH_SETTING_BUTTON_LOCATOR))
                   logging.info("嘗試點擊模態框 '批量设置' 按鈕...")
                   driver.execute_script("arguments[0].click();", batch_setting_button)
                   time.sleep(1.5) 
                   try:
                       all_present_option = WebDriverWait(driver, WAIT_TIMEOUT_MEDIUM).until(EC.element_to_be_clickable(MODAL_BATCH_ALL_PRESENT_LOCATOR))
                       logging.info("嘗試點擊 '全部出勤' 選項...")
                       driver.execute_script("arguments[0].click();", all_present_option)
                       logging.info("已點擊 '全部出勤' 選項。")
                       time.sleep(0.5)
                   except TimeoutException:
                       logging.warning(f"未找到 '全部出勤' 選項，或者它不可點擊。截图分析。")
                       if driver and not kwargs.get('__session_invalid_flag__', False):
                           save_error_artifacts(driver, f"all_present_option_timeout_btn_{processed_successfully_count+1}")
                       try: driver.find_element(By.TAG_NAME, "body").click() 
                       except: pass
                except TimeoutException:
                   logging.info("未找到 '批量设置' 按鈕，或它不可點擊。將嘗試直接提交。")
                
                # Submit
                submit_button_modal_el = WebDriverWait(driver, WAIT_TIMEOUT_MEDIUM).until(EC.element_to_be_clickable(MODAL_SUBMIT_ATTENDANCE_BUTTON_LOCATOR))
                logging.info(f"嘗試點擊模態框內的 '提交考勤' 按鈕...")
                driver.execute_script("arguments[0].click();", submit_button_modal_el)
                logging.info("已點擊 '提交考勤' 按鈕。")
                time.sleep(3.0)

                # Verify success
                logging.info("等待模態框消失或標題變為 '修改考勤'...")
                WebDriverWait(driver, WAIT_TIMEOUT_MEDIUM).until(EC.any_of(
                    EC.invisibility_of_element_located((By.XPATH, MODAL_TITLE_SUBMIT_XPATH)),
                    EC.visibility_of_element_located((By.XPATH, MODAL_TITLE_MODIFY_XPATH))
                ))
                logging.info(f"'{course_name_for_log}' 的模態框已成功處理 (原提交模態框消失或標題變為 '修改考勤')。")
                processed_successfully_count += 1
                modal_processed = True
                
                # Try to close any lingering modal (e.g., the "Modify Attendance" one) quickly
                try:
                    current_modals = driver.find_elements(By.XPATH, MODAL_ROOT_VISIBLE_XPATH)
                    if current_modals and current_modals[0].is_displayed():
                        logging.info("检测到残留模态框，尝试快速关闭。")
                        try:
                            cancel_btn = WebDriverWait(driver, 2).until(EC.element_to_be_clickable(MODAL_CANCEL_BUTTON_LOCATOR))
                            cancel_btn.click()
                        except: # Fallback to X button
                            WebDriverWait(driver, 2).until(EC.element_to_be_clickable(MODAL_CLOSE_X_BUTTON_LOCATOR)).click()
                        logging.info("已尝试关闭残留模态框。")
                        # Short wait for it to disappear
                        WebDriverWait(driver, 3).until_not(EC.visibility_of_element_located((By.XPATH, MODAL_ROOT_VISIBLE_XPATH)))
                except (NoSuchElementException, TimeoutException):
                    logging.debug("未检测到残留模态框或已自行关闭。")
                except Exception as e_close_lingering:
                    logging.warning(f"关闭残留模态框时出错: {e_close_lingering}")

            except Exception as e_modal:
                logging.error(f"处理模态框时发生未捕获的错误: {e_modal}", exc_info=True)
                modal_processed = False
        
        if not modal_processed:
            logging.warning(f"课程 '{course_name_for_log}' 的模态框未成功处理。")
    # ... loop continues...
    # ... (rest of function remains the same) ...
    # (Rest of the script: verify_attendance and main are kept from V10.4.17 as their logic is now more generic)
    logging.info(f"考勤處理循環結束。共成功處理了 {processed_successfully_count} 個課程的考勤 (最初檢測到 {buttons_to_process_count} 個有效 '录入考勤' 按鈕).")

    if buttons_to_process_count > 0:
        if processed_successfully_count == buttons_to_process_count:
            return "all_processed_successfully"
        elif processed_successfully_count > 0:
            logging.warning(f"考勤部分處理成功 ({processed_successfully_count}/{buttons_to_process_count})。")
            return "partially_processed"
        else:
            logging.error("未成功處理任何考勤條目，儘管最初檢測到有效按鈕。")
            return "none_processed_failure"
    else:
        logging.error("意外到達處理循環後的返回邏輯，但最初未檢測到有效处理按钮 (buttons_to_process_count == 0)。此为 process_attendance 内部逻辑缺陷。")
        return "unknown_state_no_initial_buttons"

# --- 驗證考勤 ---
def verify_attendance(driver, process_status_str, **kwargs):
    # ... (Using V10.4.17's verify_attendance, as its generic logic is sound)
    logging.info(f"開始驗證考勤結果 (處理狀態: {process_status_str})..."); time.sleep(2 + time.time()%1.0)
    try: _ = driver.current_url
    except InvalidSessionIdException: logging.error("驗證考勤前檢測到 Session 失效。"); kwargs['__session_invalid_flag__'] = True; raise
    except WebDriverException as e:
         if "invalid session id" in str(e).lower() or "chrome not reachable" in str(e).lower(): kwargs['__session_invalid_flag__'] = True; raise InvalidSessionIdException("Session invalid checking URL before verification")
         logging.warning(f"驗證考勤前檢查 URL 出錯: {e}")

    record_text = "录入考勤"
    modify_text = "修改考勤"
    calendar_context_xpath = "//div[@id='export-class']"
    
    record_buttons_locator_broad = (By.XPATH, f"{calendar_context_xpath}//div[normalize-space(.)='{record_text}']")
    modify_buttons_locator_broad = (By.XPATH, f"{calendar_context_xpath}//div[normalize-space(.)='{modify_text}']")

    has_visible_course_card_locator = (By.XPATH, f"{calendar_context_xpath}//div[.//h3[normalize-space(.)!='']]")


    verification_successful = False
    try:
        logging.info(f"驗證：查找是否還有可見的、在有效卡片内的日曆 '{record_text}' 按鈕...")
        logging.debug(f"Attempting to find record buttons for verification with broad XPath: {record_buttons_locator_broad[1]}")
        remaining_valid_record_buttons = []
        try:
            possible_buttons = WebDriverWait(driver, WAIT_TIMEOUT_VERY_SHORT).until(
                EC.presence_of_all_elements_located(record_buttons_locator_broad)
            )
            for btn in possible_buttons:
                if is_button_in_valid_card(driver, btn):
                    remaining_valid_record_buttons.append(btn)
            
            if not remaining_valid_record_buttons:
                 logging.info(f"驗證：未找到任何可見的、在有效卡片内的日曆 '{record_text}' 按鈕。")
            else:
                 logging.info(f"驗證：找到 {len(remaining_valid_record_buttons)} 個可見的、在有效卡片内的日曆 '{record_text}' 按鈕。")
        except TimeoutException:
             logging.info(f"驗證：在 {WAIT_TIMEOUT_VERY_SHORT}s 内未找到 '{record_text}' 的 presence (日曆區域，寬泛查找)。")
        except InvalidSessionIdException:
            logging.error(f"驗證查找 '{record_text}' 按鈕時 Session 失效。", exc_info=False); kwargs['__session_invalid_flag__'] = True; raise
        except WebDriverException as e_verify_find_wd:
             if "invalid selector" in str(e_verify_find_wd).lower():
                logging.error(f"驗證查找 '{record_text}' 按鈕時遇到無效選擇器錯誤: {e_verify_find_wd}", exc_info=True)
                if driver and not kwargs.get('__session_invalid_flag__', False): save_error_artifacts(driver, "verify_record_button_invalid_selector")
                return False
             elif "invalid session id" in str(e_verify_find_wd).lower() or "chrome not reachable" in str(e_verify_find_wd).lower():
                 kwargs['__session_invalid_flag__'] = True; raise
             else:
                logging.error(f"驗證查找 '{record_text}' 按鈕時發生 WebDriver 異常: {e_verify_find_wd}", exc_info=True)
                if driver and not kwargs.get('__session_invalid_flag__', False): save_error_artifacts(driver, "verification_find_record_webdriver_error")
             return False
        except Exception as e_verify_find_general:
             logging.error(f"驗證查找 '{record_text}' 按鈕時發生錯誤: {e_verify_find_general}", exc_info=True)
             if driver and not kwargs.get('__session_invalid_flag__', False): save_error_artifacts(driver, "verification_find_record_error")
             return False

        if process_status_str in ["all_processed_successfully", "partially_processed", "already_done"]:
            if not remaining_valid_record_buttons:
                logging.info(f"驗證通過：處理狀態為 '{process_status_str}' 且日曆中未找到殘留的有效 '{record_text}' 按鈕。")
                verification_successful = True
                try:
                    modify_buttons_elements = driver.find_elements(*modify_buttons_locator_broad)
                    visible_modify = []
                    for btn in modify_buttons_elements:
                        if is_button_in_valid_card(driver, btn):
                            visible_modify.append(btn)
                    
                    if visible_modify:
                        logging.info(f"輔助驗證：找到 {len(visible_modify)} 個可見的 '{modify_text}' 按鈕 (在卡片内)。符合預期。")
                    elif process_status_str == "all_processed_successfully":
                        try:
                            WebDriverWait(driver, WAIT_TIMEOUT_VERY_SHORT).until_not(EC.visibility_of_element_located(has_visible_course_card_locator))
                            logging.info("輔助驗證：未找到修改按鈕，且日曆区域也未找到可见课程卡片。")
                        except TimeoutException:
                             if process_status_str == "all_processed_successfully":
                                logging.warning(f"輔助驗證：處理狀態為 '{process_status_str}'，未找到有效录入/修改按钮，但日曆中仍有可见课程卡片。")
                except Exception as e_aux_verify:
                    logging.warning(f"輔助驗證時出錯: {e_aux_verify}")
            else:
                logging.error(f"驗證失敗：處理狀態為 '{process_status_str}' 但仍在日曆中找到 {len(remaining_valid_record_buttons)} 個有效 '{record_text}' 按鈕。")
                if driver and not kwargs.get('__session_invalid_flag__', False): save_error_artifacts(driver, f"verification_failed_record_after_{process_status_str.replace(' ','_')}")
                verification_successful = False

        elif process_status_str in ["no_schedule", "calendar_empty_but_verify_needed", "no_action_needed_after_initial_check", "no_action_needed_before_loop", "no_buttons_to_process_in_loop", "calendar_has_cards_no_buttons_verify_needed", "no_buttons_processed_in_loop_unexpectedly", "unknown_state_no_initial_buttons", "failure_invalid_selector_record_btn", "failure_invalid_selector_modify_btn", "failure_invalid_selector_has_card", "failure_exception_has_card"]:
            if not remaining_valid_record_buttons:
                logging.info(f"驗證通過（條件性）：處理流程為 '{process_status_str}'，且日曆中未找到有效 '{record_text}' 按鈕。")
                verification_successful = True
            else:
                logging.error(f"驗證失敗：處理流程聲稱 '{process_status_str}'，但仍在日曆中找到 {len(remaining_valid_record_buttons)} 個有效 '{record_text}' 按鈕。")
                if driver and not kwargs.get('__session_invalid_flag__', False): save_error_artifacts(driver, f"verification_failed_contradiction_{process_status_str.replace(' ','_')}")
                verification_successful = False
        elif process_status_str in ["none_processed_failure", "initial_failure"] or process_status_str.startswith("failure_exception_") or process_status_str.startswith("failure_webdriver_exception_") :
            logging.info(f"驗證步驟：由於處理狀態為 '{process_status_str}' (失敗狀態)，驗證結果將基於是否還有有效录入按钮。")
            if remaining_valid_record_buttons:
                logging.error(f"驗證確認失敗：處理已失败，且日曆中仍有 {len(remaining_valid_record_buttons)} 個有效 '{record_text}' 按鈕。")
                verification_successful = False
            else:
                logging.info(f"驗證：處理已失败，但日曆中未找到有效 '{record_text}' 按鈕。")
                verification_successful = True 
        else:
            logging.error(f"驗證：未知的處理狀態 '{process_status_str}'。檢查是否還有有效 '{record_text}' 按鈕。")
            if remaining_valid_record_buttons:
                logging.error(f"驗證失敗：未知處理狀態，且找到 {len(remaining_valid_record_buttons)} 個殘留的有效 '{record_text}' 按鈕。")
                verification_successful = False
            else:
                logging.info(f"驗證：未知處理狀態，但未找到有效 '{record_text}' 按鈕。")
                verification_successful = True

        if verification_successful: logging.info("考勤驗證步驟判定：符合預期。")
        else: logging.error("考勤驗證步驟判定：不符合預期。")
        return verification_successful

    except InvalidSessionIdException: logging.error("驗證過程中 Session 失效。", exc_info=False); kwargs['__session_invalid_flag__'] = True; raise
    except WebDriverException as e_verify_main_wd:
         if "invalid session id" in str(e_verify_main_wd).lower() or "chrome not reachable" in str(e_verify_main_wd).lower():
             kwargs['__session_invalid_flag__'] = True; raise
         logging.error(f"驗證過程中發生 WebDriver 異常: {e_verify_main_wd}", exc_info=True)
         if driver and not kwargs.get('__session_invalid_flag__', False): save_error_artifacts(driver, "verification_webdriver_error")
         raise
    except Exception as e_verify_main_general:
         logging.error(f"驗證過程中發生嚴重錯誤: {e_verify_main_general}", exc_info=True)
         if driver and not kwargs.get('__session_invalid_flag__', False): save_error_artifacts(driver, "verification_fatal_error")
         raise


# --- 主函數 ---
def main():
    script_version_name = "V10.4.18 - Robust Interactive Logic" # CHANGED V10.4.18
    start_time_dt = datetime.now(BEIJING_TZ)
    logging.info(f"--- 腳本開始執行 ({script_version_name}): {start_time_dt.strftime('%Y-%m-%d %H:%M:%S %Z%z')} ---")
    start_time_ts = time.time()

    driver = None
    final_success = False
    process_status_str = "initial_failure"
    verify_status_bool = False
    session_invalid_flag = False

    shared_kwargs = {'__session_invalid_flag__': session_invalid_flag}
    shared_kwargs['__outer_kwargs__'] = shared_kwargs

    try:
        driver = get_webdriver(**shared_kwargs)
        session_invalid_flag = shared_kwargs['__session_invalid_flag__']
        if session_invalid_flag: raise InvalidSessionIdException("Session invalid during webdriver initialization")

        login_ok = login(driver, LOGIN_URL, USERNAME, PASSWORD, **shared_kwargs)
        session_invalid_flag = shared_kwargs['__session_invalid_flag__']
        if session_invalid_flag: raise InvalidSessionIdException("Session invalid during login")
        if not login_ok :
            logging.error("Login function returned False without InvalidSessionIdException.")
            raise Exception("Login failed without InvalidSessionIdException")

        binding_skipped = skip_phone_binding(driver, **shared_kwargs)
        session_invalid_flag = shared_kwargs['__session_invalid_flag__']
        if session_invalid_flag: raise InvalidSessionIdException("Session invalid during skip binding")
        if not binding_skipped: logging.warning("跳過手機綁定步驟可能遇到問題，但嘗試繼續...")
        time.sleep(2 + time.time()%1.0)

        try:
            process_status_str = process_attendance(driver, **shared_kwargs)
            session_invalid_flag = shared_kwargs['__session_invalid_flag__']
            if session_invalid_flag: raise InvalidSessionIdException("Session invalid during process attendance")

            if process_status_str in ["all_processed_successfully", "already_done"]:
                logging.info(f"考勤處理步驟完成，狀態: {process_status_str}。")
            elif process_status_str == "partially_processed":
                 logging.warning(f"考勤處理步驟部分完成，狀態: {process_status_str}。")
            else: # Covers all other states, including failures and "nothing to do" states
                 logging.info(f"考勤處理步驟返回狀態: {process_status_str}。將進行驗證。")

        except InvalidSessionIdException as e:
             logging.error(f"考勤處理步驟中 Session 失效: {e}", exc_info=False)
             session_invalid_flag = True; process_status_str = "failure_session_invalid"
        except Exception as process_err:
            session_invalid_flag = shared_kwargs.get('__session_invalid_flag__', session_invalid_flag)
            logging.error(f"考勤處理步驟中發生未捕獲異常: {process_err}", exc_info=True)
            if driver and not session_invalid_flag: save_error_artifacts(driver, "process_uncaught_error")
            process_status_str = f"failure_exception_{type(process_err).__name__}"


        should_verify = not session_invalid_flag

        if driver and should_verify:
             try:
                  verify_status_bool = verify_attendance(driver, process_status_str, **shared_kwargs)
                  session_invalid_flag = shared_kwargs['__session_invalid_flag__']
                  if session_invalid_flag: raise InvalidSessionIdException("Session invalid during verify attendance")
             except Exception as verify_err:
                  session_invalid_flag = shared_kwargs.get('__session_invalid_flag__', session_invalid_flag)
                  logging.error(f"考勤驗證步驟中發生未處理異常: {verify_err}", exc_info=True)
                  if driver and not session_invalid_flag: save_error_artifacts(driver, "verify_uncaught_error")
                  verify_status_bool = False
        elif session_invalid_flag:
            logging.warning("因 Session 失效，跳過驗證步驟，結果視為失敗。")
            verify_status_bool = False;

        # Final success determination
        if session_invalid_flag:
            logging.error("因瀏覽器 Session 失效導致執行失敗。")
            final_success = False
        else:
            if process_status_str in ["all_processed_successfully", "already_done"]:
                if verify_status_bool:
                    logging.info(f"考勤處理和驗證均成功完成 (狀態: {process_status_str})。")
                    final_success = True
                else: 
                    logging.error(f"考勤處理狀態為 '{process_status_str}'，但驗證失敗。最終狀態視為失敗。")
                    final_success = False
            elif process_status_str == "partially_processed":
                if verify_status_bool:
                    logging.warning(f"考勤部分處理成功 ({process_status_str})，驗證通過。最終狀態視為警告性成功。")
                    final_success = True 
                else:
                    logging.error(f"考勤部分處理成功 ({process_status_str})，但驗證失敗。最終狀態視為失敗。")
                    final_success = False
            else: 
                # For all other cases, including "none_processed", "calendar_empty", and any "failure_" state,
                # the result should be a failure. The verify_status_bool just confirms the final state of the page.
                logging.error(f"考勤處理步驟未正常完成或返回非成功狀態 '{process_status_str}'。驗證狀態: {'通过' if verify_status_bool else '失败/未执行'}。最終狀態視為失敗。")
                final_success = False

    except requests.exceptions.RequestException as conn_err_main:
        logging.error(f"初始化 WebDriver 時發生網絡錯誤 (webdriver-manager): {conn_err_main}", exc_info=True); final_success = False
    except InvalidSessionIdException as e_main_session:
        logging.error(f"主流程捕獲到無效的 Session ID: {e_main_session}", exc_info=False); session_invalid_flag = True; final_success = False
    except Exception as e_main:
        session_invalid_flag = shared_kwargs.get('__session_invalid_flag__', session_invalid_flag)
        logging.error(f"腳本主流程發生未捕獲的嚴重錯誤: {type(e_main).__name__}: {e_main}", exc_info=True)
        if driver and not session_invalid_flag: save_error_artifacts(driver, f"fatal_uncaught_error_{type(e_main).__name__}")
        final_success = False

    finally:
        if driver:
            try:
                is_session_finally_invalid = shared_kwargs.get('__session_invalid_flag__', False)
                if not is_session_finally_invalid:
                    try:
                        _ = driver.title
                    except WebDriverException as check_quit_err:
                        if any(msg in str(check_quit_err).lower() for msg in [
                               "invalid session id", "session deleted", "chrome not reachable",
                               "no such execution context", "target window already closed"
                           ]):
                             logging.warning("嘗試關閉 WebDriver 前檢測到 Session 已失效。")
                             is_session_finally_invalid = True
                        else:
                             logging.warning(f"嘗試關閉 WebDriver 前檢查 Session 時發生異常: {check_quit_err}")

                if not is_session_finally_invalid:
                     logging.info("嘗試關閉 WebDriver...")
                     driver.quit()
                     logging.info("WebDriver 已關閉。")
                else:
                    logging.info("Session 已失效，通常 driver.quit() 會失敗或無效，跳過 quit。")
            except InvalidSessionIdException: logging.warning("嘗試關閉 WebDriver 時 Session ID 已無效 (重複檢測)。")
            except WebDriverException as quit_wd_err: logging.error(f"關閉 WebDriver 時發生 WebDriver 異常: {quit_wd_err}")
            except Exception as quit_err: logging.error(f"關閉 WebDriver 時發生未知錯誤: {quit_err}")

        end_time_dt = datetime.now(BEIJING_TZ)
        end_time_ts = time.time()
        logging.info(f"--- 腳本執行完畢: {end_time_dt.strftime('%Y-%m-%d %H:%M:%S %Z%z')} ---")
        logging.info(f"--- 總耗時: {end_time_ts - start_time_ts:.2f} 秒 ---")
        logging.info(f"--- 最終執行狀態: {'成功' if final_success else '失敗'} ---")
        print(f"腳本執行完成，狀態: {'成功' if final_success else '失敗'}。詳情請查看日誌文件: {LOG_FILE}")

        if not final_success: sys.exit(1)

if __name__ == "__main__":
    script_dir = os.path.dirname(os.path.abspath(__file__))
    try:
        if script_dir:
            os.chdir(script_dir)
            logging.info(f"腳本工作目錄設置為: {script_dir}")
        else:
            current_dir = os.getcwd()
            logging.warning(f"無法確定腳本所在目錄，將使用當前工作目錄: {current_dir}")
    except Exception as e_chdir:
        logging.error(f"設置工作目錄失敗: {e_chdir}")
    main()
