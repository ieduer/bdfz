# Seiue 全站真实 API 抓取 Runbook（2026-04-15）

> 目标：不是靠代码猜，而是基于 **本机现成凭据 + 真实登录 + 真实页面交互 + 真实请求回放**，把 Seiue / 门户相关 API 尽可能抓全，并形成可复现路径。

## 一、固定原则

1. **Seiue 账号只读 `~/.secrets.env`**
   - 使用 `SEIUE_USERNAME`
   - 使用 `SEIUE_PASSWORD`
   - 不再相信当前 shell 注入的旧变量
2. **门户 SSO 也只读 `~/.secrets.env`**
   - 使用 `BDFZ_PORTAL_USERNAME`
   - 使用 `BDFZ_PORTAL_PASSWORD`
3. **真实优先**
   - 先真实登录
   - 再真实浏览器交互
   - 再抽取真实请求
   - 再用 Bearer 回放验活
4. **写操作谨慎**
   - 若某 API 只有提交动作才会出现，必须按“测试写入 → 抓请求 → 删除/回滚”闭环做
   - 不允许把未执行的写接口当成已确认接口写进主表

---

## 二、抓取层次

### 第 0 层：凭据验真
- 目标：确认 `~/.secrets.env` 中 Seiue 直登可用
- 方法：
  1. `POST https://passport.seiue.com/login?school_id=3`
  2. `POST https://passport.seiue.com/authorize`
- 成功标准：
  - `login` 成功
  - `authorize` 返回 `access_token`
  - 返回 `active_reflection_id`

### 第 1 层：门户 SSO 打通
- 目标：确认从门户进入 Seiue 的真实链路可用
- 路径：
  1. 打开 `https://chalk-c3.seiue.com/`
  2. 选择学校（北大附中高中本部）
  3. 点击 `使用门户登录`
  4. 输入 `BDFZ_PORTAL_USERNAME / BDFZ_PORTAL_PASSWORD`
  5. 进入门户网关
  6. 点击 `希悦（高中部）`
  7. 成功进入 `chalk-c3.seiue.com`

### 第 2 层：首页 / 入口页抓取
- 目标：拿到首页、通知、档案、导师组等基础入口真实 API
- 优先页面：
  - 首页
  - 通知
  - 档案
  - 导师组
  - 课程列表 / 课程主页

### 第 3 层：详情页 / 功能页抓取
- 目标：继续拿到课程详情、导师组详情、成绩页、考勤页的真实 API
- 优先动作：
  - 查看详情
  - 修改考勤
  - 录入成绩
  - 查看回放
  - 发送通知

### 第 4 层：回放验活
- 目标：避免“只是页面里出现过 URL”
- 方法：
  - 用 `~/.secrets.env` 中的 Seiue账号重新获取 Bearer
  - 对抓到的 `api.seiue.com` URL 逐条 `GET` 回放
  - 记录：
    - status
    - content-type
- 备注：
  - `302` 对网盘签名类属于正常
  - `api.pkuschool.edu.cn` 目前保留真实前端命中记录，未做独立 cookie 回放

### 第 5 层：写操作闭环（待继续）
- 只有进入以下页面并完成可回滚测试后，才可新增“真实 mutation API”条目：
  - 考勤修改提交
  - 成绩写入提交
  - 通知发送提交
  - 约谈创建/提交/结束
  - 作业创建/修改/删除
  - 流程提交/审批

---

## 三、当前已完成

### 已完成的真实链路
- `~/.secrets.env` 中 Seiue 直登已验证成功
- 门户 SSO → Seiue 首页已验证成功
- 已完成的真实页面：
  - 首页
  - 通知
  - 档案
  - 导师组
  - 修改考勤入口
  - 录入成绩入口
  - 查看回放入口
  - 发送通知入口

### 已完成的真实产物
全部位于：
- `/home/suen/.openclaw/workspace/output/playwright/`

重点文件：
- `direct-auth-probe.json`
- `captured-url-replay.json`
- `walk-summary.json`
- `walk-*.json`
- `sso-step4-after-portal-submit.json`
- `fullsso-step5-seiue-after-click.json`
- `sso-action-修改考勤.json`
- `sso-action-录入成绩.json`
- `sso-action-发送通知.json`

---

## 四、当前抓到的 API 面

### 已确认的新增真实面
- Portal / growp / BI
- Chalk 首页 / 权限 / 角色 / 布局 / 通知 / 群组 / 自定义群组 / 词典 / 计数器
- SCMS 班级 / 时间表 / 校历 / 在线课 / 选科相关
- SAMS 考勤详情 / 班级考勤 / 请假类型
- VNAS assessment / stages / settings / exam scoring / grades
- SGMS certification
- AIS teacher bot / chat bot
- Passport hooks / authorize

### 当前仍未完成的面
这些还需要继续做“写操作闭环”，否则不能算全：
- 考勤提交写入接口（不是只读详情）
- 成绩写入 / 保存 / 发布接口
- 通知发送真正提交接口
- 作业创建 / 更新 / 删除页面触发链路
- 约谈 / chat 表单提交更多前台入口
- 流程审批 / 请假提交 / 撤回 / 审批动作

---

## 五、后续执行顺序（固定）

1. **先抓 mutation 入口页**
   - 考勤修改
   - 成绩录入
   - 发送通知
2. **再做最小写入测试**
   - 用测试内容
   - 明确记录变更对象
3. **立即删除 / 回滚**
4. **把 mutation URL、方法、回滚结果写入文档**
5. **更新主 API 总表**

---

## 六、结果沉淀规则

- 主增补清单：`docs/SEIUE_API_REAL_CAPTURE_2026-04-15.md`
- 主总表：`docs/SEIUE_API_CATALOG_2026-04-15.md`
- 本 runbook：`docs/SEIUE_API_CAPTURE_RUNBOOK_2026-04-15.md`

后续继续抓时，优先更新“真实抓取增补”文档，再回填主总表。
