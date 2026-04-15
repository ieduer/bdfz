# Seiue 网站 API 清单（字段级版本，基于本机 + GitHub 代码实扫）

> 补充说明（2026-04-15 晚间真实抓取增补）
>
> - 本文是“代码实扫 + 历史验证链路”主表。
> - 当晚基于 `~/.secrets.env` 中真实凭据、门户 SSO、真实页面交互、真实 URL 回放得到的新增接口，另见：
>   - `docs/SEIUE_API_REAL_CAPTURE_2026-04-15.md`
>   - `docs/SEIUE_API_CAPTURE_RUNBOOK_2026-04-15.md`

> 说明
>
> - 这不是 Seiue 官方开放平台文档，而是**基于本机代码仓与相关脚本实扫**整理出的字段级文档。
> - 每个 API 尽量补齐：**方法 / 参数 / 返回字段 / 鉴权要求**。
> - **返回字段只写代码中已实际使用、或能从现有实现确认的字段**；不伪造完整 schema。
> - 同一路径若在多个项目重复出现，统一合并说明。
> - 文中 `Bearer` / `x-school-id` / `x-role` / `x-reflection-id` 默认为 Seiue 教师侧常见头。

---

## 通用鉴权要求

除 `passport.seiue.com` 登录链路外，绝大多数 `api.seiue.com` 接口都要求：

### 请求头
- `Authorization: Bearer <access_token>`
- `x-school-id: 3`
- `x-role: teacher`
- `x-reflection-id: <active_reflection_id>`
- 常见还会带：
  - `Origin: https://chalk-c3.seiue.com`
  - `Referer: https://chalk-c3.seiue.com/`
  - `Accept: application/json, text/plain, */*`

### Bearer 获取方式
1. `POST https://passport.seiue.com/login?school_id=3`
2. `POST https://passport.seiue.com/authorize`
3. 从返回中取：
   - `access_token`
   - `active_reflection_id`

---

# 一、认证 / 鉴权 / 入口

## 1. `POST https://passport.seiue.com/login?school_id=3`
- **作用**：教师侧登录，建立会话 cookie。
- **方法**：`POST`
- **参数**（表单）：
  - `email`: 用户名/邮箱
  - `password`: 密码
- **返回字段**：
  - 代码未直接消费 JSON 字段；主要依赖 **cookie 会话建立成功**。
- **鉴权要求**：
  - 无 Bearer
  - 需要：
    - `Content-Type: application/x-www-form-urlencoded`
    - `Origin: https://passport.seiue.com`
    - `Referer: https://passport.seiue.com/login?school_id=3`
- **来源**：
  - `kseiue-worker/src/index.js`
  - `my-seiue-app/backend/index.py`
  - `bdfz/seiuestu.sh`

## 2. `POST https://passport.seiue.com/authorize`
- **作用**：在登录会话基础上签发 token。
- **方法**：`POST`
- **参数**（表单）：
  - `client_id=GpxvnjhVKt56qTmnPWH1sA`
  - `response_type=token`
- **返回字段**（代码已用到）：
  - `access_token`
  - `active_reflection_id`
- **鉴权要求**：
  - 依赖上一步 cookie
  - 无 Bearer
  - 常见头：
    - `Origin: https://chalk-c3.seiue.com`
    - `Referer: https://chalk-c3.seiue.com/`
- **来源**：
  - `kseiue-worker/src/index.js`
  - `my-seiue-app/backend/index.py`
  - `bdfz/seiuestu.sh`

---

# 二、日历 / 课程 / 考勤

## 3. `GET https://api.seiue.com/chalk/calendar/personals/{reflection_id}/events`
- **作用**：读取个人日历事件，常用于找当天课程。
- **方法**：`GET`
- **路径参数**：
  - `reflection_id`
- **查询参数**：
  - `start_time`
  - `end_time`
  - `expand=address,initiators`
- **返回字段**（代码已用到）：
  - 数组元素字段：
    - `type`（代码筛 `lesson`）
    - `custom.id`（考勤时间 id）
    - `subject.id`（班级/课程业务 id）
    - `title`
    - `address`（展开后可用）
    - `initiators`（展开后可用）
- **鉴权要求**：
  - Bearer + `x-school-id` + `x-role` + `x-reflection-id`
- **来源**：
  - `kseiue-worker/src/index.js`
  - `my-seiue-app/backend/index.py`
  - `bdfz/saa_decoded.sh`

## 4. `GET https://api.seiue.com/scms/class/classes/{class_id}/group-members?expand=reflection&member_type=student`
- **作用**：读取课程/班级学生列表。
- **方法**：`GET`
- **路径参数**：
  - `class_id`
- **查询参数**：
  - `expand=reflection`
  - `member_type=student`
- **返回字段**（代码已用到）：
  - 数组元素字段：
    - `reflection.id`
    - 可能还含成员基础字段
- **鉴权要求**：
  - Bearer + Seiue 业务头
- **来源**：
  - `kseiue-worker/src/index.js`
  - `my-seiue-app/backend/index.py`

## 5. `PUT https://api.seiue.com/sams/attendance/class/{class_id}/records/sync`
- **作用**：批量提交考勤。
- **方法**：`PUT`
- **路径参数**：
  - `class_id`
- **请求体**：
  - `attendance_records`: 数组
    - `tag`（如 `正常`）
    - `attendance_time_id`
    - `owner_id`
    - `source`（常见 `web`）
  - `abnormal_notice_roles`: 数组
- **返回字段**：
  - 代码未稳定消费响应体字段；主要依据 HTTP 状态判断。
- **鉴权要求**：
  - Bearer + Seiue 业务头
- **状态特征**：
  - `200/2xx`：通常成功
  - `409/422`：窗口关闭或业务拒绝（代码有专门处理）
- **来源**：
  - `kseiue-worker/src/index.js`
  - `my-seiue-app/backend/index.py`
  - `bdfz/saa_decoded.sh`

## 6. `GET https://api.seiue.com/sams/attendance/attendances-info`
- **作用**：查询课程是否已经被点名。
- **方法**：`GET`
- **查询参数**：
  - `attendance_time_id_in`
  - `biz_id_in`
  - `biz_type_in=class`
  - `expand=checked_attendance_time_ids`
  - `paginated=0`
- **返回字段**（代码已用到）：
  - 数组元素字段：
    - `checked_attendance_time_ids`（数组）
- **鉴权要求**：
  - Bearer + Seiue 业务头
- **来源**：
  - `kseiue-worker/src/index.js`
  - `my-seiue-app/backend/index.py`
  - `bdfz/saa_decoded.sh`

---

# 三、作业 / 任务 / 提交 / 批阅

## 7. `GET /chalk/task/v2/tasks/{task_id}`
- **作用**：读取单个任务详情。
- **方法**：`GET`
- **路径参数**：
  - `task_id`
- **查询参数**：
  - 无固定必填
- **返回字段**（代码/用途可确认）：
  - `id`
  - `title`
  - `group`
  - `status`
  - 其他任务基础元数据
- **鉴权要求**：
  - Bearer + Seiue 业务头
- **来源**：`bdfz/agrader.sh`

## 8. `GET /chalk/task/v2/tasks?id_in={ids}&expand=group`
- **作用**：批量查任务并展开 group。
- **方法**：`GET`
- **查询参数**：
  - `id_in`（逗号分隔）
  - `expand=group`
- **返回字段**（可确认）：
  - 数组元素字段：
    - `id`
    - `title`
    - `group`
- **鉴权要求**：
  - Bearer + Seiue 业务头
- **来源**：`bdfz/agrader.sh`

## 9. `GET /chalk/task/v2/tasks/{task_id}/assignments?expand=is_excellent,assignee,team,submission,review`
- **作用**：读取作业提交与批阅情况。
- **方法**：`GET`
- **路径参数**：
  - `task_id`
- **查询参数**：
  - `expand=is_excellent,assignee,team,submission,review`
- **返回字段**（代码/用途可确认）：
  - 数组元素字段常见含：
    - `assignee`
    - `submission`
    - `review`
    - `team`
    - `is_excellent`
- **鉴权要求**：
  - Bearer + Seiue 业务头
- **来源**：`bdfz/agrader.sh`

## 10. `POST /chalk/task/v2/assignees/{receiver_id}/tasks/{task_id}/reviews`
- **作用**：给某学生提交写评语/批阅。
- **方法**：`POST`
- **路径参数**：
  - `receiver_id`
  - `task_id`
- **请求体**（按现有自动化链路可确认）：
  - 评语文本
  - 批阅状态/内容相关字段
- **返回字段**：
  - 代码主要按 HTTP 状态判断；响应通常为 review 记录或成功标记。
- **鉴权要求**：
  - Bearer + Seiue 业务头
- **来源**：`bdfz/agrader.sh`

## 11. `PUT /chalk/task/v2/tasks/{task_id}`
- **作用**：更新任务/发布任务。
- **方法**：`PUT`
- **路径参数**：
  - `task_id`
- **请求体**：
  - 任务标题、内容、发布时间、对象、结构关联等字段
- **返回字段**：
  - 常见为更新后的任务对象
- **鉴权要求**：
  - Bearer + Seiue 业务头
- **来源依据**：历史作业自动化链路（已验证）

## 12. `POST /chalk/task/v2/tasks/$batch`
- **作用**：批量创建任务。
- **方法**：`POST`
- **请求体**：
  - 任务数组
  - 代码记忆中已确认 `role_id` 常为必填
- **2026-04-15 真实抓包已确认的最小创建字段**：
  - `allow_overdue_submit=false`
  - `domain="group"`
  - `domain_biz_id=2367132`
  - `outline_id=0`
  - `submit_enabled=true`
  - `outlines=[]`
  - `enhancer="seiue.class_homework_task"`
  - `role_id=0`
  - `title`
  - `content`（DraftJS JSON）
  - `is_team_work=false`
  - `attachments=[]`
  - `published_at`
  - `expired_at=null`
  - `general_status="published"`
  - `assignments=[{"assignee_id":...}]`
  - `custom_fields.website_url=""`
  - `custom_fields.is_all_joined=false`
  - `prev_id=0`
- **返回字段**：
  - 创建后的任务数组 / 各 task id
  - 真实抓包确认可直接返回 `id`、`labels.type`、`general_status`、`created_at`、`updated_at`
- **鉴权要求**：
  - Bearer + Seiue 业务头
- **证据边界**：
  - 代码/历史链路已知
  - 2026-04-15 已通过真实前端发包确认（201）
- **来源依据**：历史作业自动化链路（已验证）+ 2026-04-15 真实抓包

## 13. `DELETE /chalk/task/v2/tasks/{task_id}`
- **作用**：删除任务。
- **方法**：`DELETE`
- **路径参数**：
  - `task_id`
- **返回字段**：
  - 通常仅凭 `204`/`2xx` 判断成功
- **鉴权要求**：
  - Bearer + Seiue 业务头
- **证据边界**：
  - 历史链路已验证
  - 2026-04-15 已用真实测试任务 `662680` 再次确认 `204`
- **来源依据**：历史作业自动化链路（已验证）+ 2026-04-15 真实抓包回滚

---

## 13A. `POST /chalk/discussion/discussions/{discussion_id}/topics`
- **作用**：在课程班讨论区发布新 topic。
- **方法**：`POST`
- **路径参数**：
  - `discussion_id`
- **2026-04-15 真实抓包请求体**：
  - `{"content":"<讨论正文>","attachments":[]}`
- **返回字段**（真实抓包已确认）:
  - `id`（topic_id）
  - `discussion_id`
  - `creator_id`
  - `content`
  - `attachments`
  - `created_at`
  - `updated_at`
- **鉴权要求**：
  - Bearer + Seiue 业务头
- **证据边界**：
  - 2026-04-15 已通过真实前端发包确认（201）

## 13B. `DELETE /chalk/discussion/discussions/{discussion_id}/topics/{topic_id}`
- **作用**：删除讨论 topic。
- **方法**：`DELETE`
- **路径参数**：
  - `discussion_id`
  - `topic_id`
- **返回字段**：
  - 通常仅凭 `204`/`2xx` 判断成功
- **鉴权要求**：
  - Bearer + Seiue 业务头
- **证据边界**：
  - 2026-04-15 已通过真实测试 topic `707737` 确认 `204`
  - 同时确认 `/chalk/discussion/topics/{topic_id}` 为错误路径（404）

---

# 四、评分 / 成绩结构 / assessment / item

## 14. `GET /vnas/klass/items/{item_id}?expand=related_data,assessment,assessment_stage,stage`
- **作用**：读取成绩项详情。
- **方法**：`GET`
- **路径参数**：
  - `item_id`
- **查询参数**：
  - `expand=related_data,assessment,assessment_stage,stage`
- **返回字段**（代码已用到）：
  - `id`
  - `score` / 满分相关字段
  - `related_data.task_id`
  - `assessment`
  - `assessment_stage`
  - `stage`
- **鉴权要求**：
  - Bearer + Seiue 业务头
- **来源**：`bdfz/agrader.sh`

## 15. `GET /vnas/common/items/{item_id}/scores?paginated=0&type=item_score`
- **作用**：查看某 item 已有分数。
- **方法**：`GET`
- **路径参数**：
  - `item_id`
- **查询参数**：
  - `paginated=0`
  - `type=item_score`
- **返回字段**（用途可确认）：
  - 分数记录数组，通常含：
    - `owner_id`
    - `score`
    - `type`
    - `related_data`
- **鉴权要求**：
  - Bearer + Seiue 业务头
- **来源**：`bdfz/agrader.sh`

## 16. `POST /vnas/klass/items/{item_id}/scores/sync?async=true&from_task=true`
- **作用**：向成绩项写分。
- **方法**：`POST`
- **路径参数**：
  - `item_id`
- **查询参数**：
  - `async=true`
  - `from_task=true`
- **请求体**（代码已确认）：
  - `owner_id`
  - `score`
  - `review`
  - `type=item_score`
  - `related_data.task_id`
- **返回字段**：
  - 代码主要按 HTTP 状态 + 后续回查判断成功
- **鉴权要求**：
  - Bearer + Seiue 业务头
- **来源**：
  - `bdfz/agrader.sh`
  - 历史作业自动化链路

## 17. `GET /vnas/klass/items?related_data.task_id={task_id}`
## 18. `GET /vnas/klass/items?related_data[task_id]={task_id}`
## 19. `GET /vnas/common/items?related_data.task_id={task_id}`
## 20. `GET /vnas/common/items?related_data[task_id]={task_id}`
## 21. `GET /vnas/klass/items?task_id={task_id}`
## 22. `GET /vnas/common/items?task_id={task_id}`
- **作用**：按 task_id 兜底反查 item。
- **方法**：`GET`
- **查询参数**：
  - 上述各种 task_id 传法
- **返回字段**（用途可确认）：
  - item 列表，重点看：
    - `id`
    - `related_data.task_id`
    - item 名称/结构信息
- **鉴权要求**：
  - Bearer + Seiue 业务头
- **来源**：`bdfz/agrader.sh`

## 23. `GET /vnas/klass/assessments?expand=items,items.task_relations,items.task_relations.task,klass&scope_id_in={class_id}&scope_type=class&semester_id={semester_id}`
- **作用**：读取班级 assessment 及 task 映射。
- **方法**：`GET`
- **查询参数**：
  - `expand=items,items.task_relations,items.task_relations.task,klass`
  - `scope_id_in={class_id}`
  - `scope_type=class`
  - `semester_id={semester_id}`
- **返回字段**（已确认）：
  - assessment 数组
  - 每个 assessment 下：
    - `items`
    - `items[].task_relations`
    - `items[].task_relations[].task`
    - `klass`
- **鉴权要求**：
  - Bearer + Seiue 业务头
- **来源依据**：历史作业自动化链路（已验证）

## 24. `POST /vnas/klass/assessments/{assessment_id}/items`
- **作用**：在 assessment 下创建/复制 item。
- **方法**：`POST`
- **路径参数**：
  - `assessment_id`
- **请求体**：
  - item 名称、分值、结构参数、关联等
- **返回字段**：
  - 新建 item 对象，至少含 `id`
- **鉴权要求**：
  - Bearer + Seiue 业务头
- **来源依据**：历史结构复制链路（已验证）

## 25. `GET https://api.seiue.com/vnas/common/assessments/{assessment_id}?expand=items,plan&operation_type={op_type}&policy=evaluated`
- **作用**：读取某个 assessment 详情。
- **方法**：`GET`
- **路径参数**：
  - `assessment_id`
- **查询参数**：
  - `expand=items,plan`
  - `operation_type={op_type}`
  - `policy=evaluated`
- **返回字段**（通知脚本可确认）：
  - `id`
  - `items`
  - `plan`
  - `title`/名称相关字段
- **鉴权要求**：
  - Bearer + Seiue 业务头
- **来源**：`bdfz/seiue-notify.sh`

## 26. `GET https://api.seiue.com/vnas/common/items/{item_id}/score-details?expand=item,evaluator&operation_type={op_type}&owner_id={owner_id}&paginated=0&policy=evaluated`
- **作用**：读取 item 对某个学生的详细评分记录。
- **方法**：`GET`
- **路径参数**：
  - `item_id`
- **查询参数**：
  - `expand=item,evaluator`
  - `operation_type={op_type}`
  - `owner_id={owner_id}`
  - `paginated=0`
  - `policy=evaluated`
- **返回字段**（通知脚本可确认）：
  - 数组元素字段：
    - `item`
    - `evaluator`
    - `score`
    - 评价内容/详情字段
- **鉴权要求**：
  - Bearer + Seiue 业务头
- **来源**：`bdfz/seiue-notify.sh`

## 27. `GET /vnas/klass/owners/{owner_id}/transcript`
- **作用**：读取学生成绩单。
- **方法**：`GET`
- **路径参数**：
  - `owner_id`
- **返回字段**（用途可确认）：
  - transcript 对象
  - 成绩项/汇总结构
- **鉴权要求**：
  - Bearer + Seiue 业务头
- **来源**：`bdfz/seiuestu.sh`

---

# 五、通知 / 消息 / 约谈 / 聊天

## 28. `GET https://api.seiue.com/chalk/me/received-messages`
- **作用**：拉取系统消息/通知。
- **方法**：`GET`
- **查询参数**（脚本已用）：
  - `owner.id`
  - `type=message`
  - `notice=true`
  - `readed=false`
  - `expand=sender_reflection,aggregated_messages`
- **返回字段**（已确认）：
  - 消息数组，常见字段：
    - `id`
    - `title`
    - `content`
    - `published_at` / `created_at`
    - `sender_reflection`
    - `aggregated_messages`
- **鉴权要求**：
  - Bearer + Seiue 业务头
- **来源**：`bdfz/seiue-notify.sh`

## 29. `GET https://api.seiue.com/chalk/chat/instances/{instance_id}/chats/{chat_id}?expand=members,owner,discussion,members.reflection,members.reflection.pupil`
- **作用**：读取聊天/约谈详情。
- **方法**：`GET`
- **路径参数**：
  - `instance_id`
  - `chat_id`
- **查询参数**：
  - `expand=members,owner,discussion,members.reflection,members.reflection.pupil`
- **返回字段**（已确认）：
  - `members`
  - `owner`
  - `discussion`
  - `members[].reflection`
  - `members[].reflection.pupil`
- **鉴权要求**：
  - Bearer + Seiue 业务头
- **来源**：`bdfz/seiue-notify.sh`

## 30. `GET https://api.seiue.com/chalk/chat/chats/{chat_id}/schedule-section?expand=section_members,schedule,schedule.compere,section_members.reflection`
- **作用**：读取约谈的时间/场次/参与者信息。
- **方法**：`GET`
- **路径参数**：
  - `chat_id`
- **查询参数**：
  - `expand=section_members,schedule,schedule.compere,section_members.reflection`
- **返回字段**（已确认）：
  - `section_members`
  - `schedule`
  - `schedule.compere`
  - `section_members[].reflection`
- **鉴权要求**：
  - Bearer + Seiue 业务头
- **来源**：`bdfz/seiue-notify.sh`

## 31. `GET https://api.seiue.com/chalk/chat/students/{student_id}/chats?expand=owner&per_page=10&sort=-start_time&type=chat`
- **作用**：按学生取最近聊天记录。
- **方法**：`GET`
- **路径参数**：
  - `student_id`
- **查询参数**：
  - `expand=owner`
  - `per_page=10`
  - `sort=-start_time`
  - `type=chat`
- **返回字段**（已确认）：
  - 聊天数组
  - 元素内可用：`owner`、开始时间、标题等
- **鉴权要求**：
  - Bearer + Seiue 业务头
- **来源**：`bdfz/seiuestu.sh`

## 32. `GET https://api.seiue.com/form/chat/chat-form/{chat_id}/answers?paginated=0`
- **作用**：读取约谈表单答案。
- **方法**：`GET`
- **路径参数**：
  - `chat_id`
- **查询参数**：
  - `paginated=0`
- **返回字段**（可确认）：
  - 答案数组，通常含：
    - `form_template_field_id`
    - `label` / 文本值
    - `attributes.attachments`
- **鉴权要求**：
  - Bearer + Seiue 业务头
- **来源**：`bdfz/seiue-notify.sh`

## 33. `GET https://api.seiue.com/form/chat/chat-form-template?expand=form_template_fields&id={template_id}[&instance_id={instance_id}]`
- **作用**：读取聊天表单模板。
- **方法**：`GET`
- **查询参数**：
  - `expand=form_template_fields`
  - `id={template_id}`
  - `instance_id={instance_id}`（可选）
- **返回字段**（已确认）：
  - 模板数组/对象
  - `form_template_fields`
  - 字段 id / label / 类型
- **鉴权要求**：
  - Bearer + Seiue 业务头
- **来源**：`bdfz/seiue-notify.sh`

## 34. `POST {SEIUE_BASE}/chalk/chat/instances/{CHAT_INSTANCE_ID}/chats`
- **作用**：创建约谈/聊天。
- **方法**：`POST`
- **路径参数**：
  - `CHAT_INSTANCE_ID`
- **请求体**（代码已确认）：
  - `title`
  - `content`
  - `attachments`
  - `member_ids`
  - `place_name`
  - `start_time`
  - `end_time`
  - `custom_fields.chat_method`
  - `custom_fields.is_classin`
  - `custom_fields.chat_type`
- **返回字段**（代码已用到）：
  - `id`
- **鉴权要求**：
  - Bearer + Seiue 业务头
- **来源**：`bdfz/mentee.sh`

## 35. `GET {SEIUE_BASE}/chalk/chat/instances/{CHAT_INSTANCE_ID}/chats/{chat_id}?expand=chat_form,form,forms`
- **作用**：读取聊天并解析 form 实例。
- **方法**：`GET`
- **路径参数**：
  - `CHAT_INSTANCE_ID`
  - `chat_id`
- **查询参数**：
  - `expand=chat_form,form,forms`
- **返回字段**（代码已用到）：
  - `custom_fields.form_id`
  - `chat_form.id`
  - `form.id`
  - `forms[].id`
- **鉴权要求**：
  - Bearer + Seiue 业务头
- **来源**：`bdfz/mentee.sh`

## 36. `GET {SEIUE_BASE}/chalk/chat/instances/{CHAT_INSTANCE_ID}/chats/{chat_id}`
- **作用**：无 expand 的聊天详情兜底读取。
- **方法**：`GET`
- **路径参数**：
  - `CHAT_INSTANCE_ID`
  - `chat_id`
- **返回字段**：
  - 与聊天对象基础字段一致，代码主要用它兜底找 `form_id`
- **鉴权要求**：
  - Bearer + Seiue 业务头
- **来源**：`bdfz/mentee.sh`

## 37. `POST {SEIUE_BASE}/chalk/chat/chats/{chat_id}/chat-form/{CHAT_FORM_TEMPLATE_ID}/answers`
- **作用**：提交聊天表单答案。
- **方法**：`POST`
- **路径参数**：
  - `chat_id`
  - `CHAT_FORM_TEMPLATE_ID`
- **请求体**（数组，代码已确认）：
  - 文本答案项：
    - `label`
    - `form_id`
    - `form_template_field_id`
  - 附件项：
    - `form_id`
    - `form_template_field_id`
    - `attributes.attachments`
- **返回字段**：
  - 代码未稳定消费响应字段；主要按 HTTP 成功判断
- **鉴权要求**：
  - Bearer + Seiue 业务头
- **来源**：`bdfz/mentee.sh`

## 38. `PATCH {SEIUE_BASE}/chalk/chat/instances/{CHAT_INSTANCE_ID}/chats/{chat_id}`
- **作用**：更新聊天状态。
- **方法**：`PATCH`
- **路径参数**：
  - `CHAT_INSTANCE_ID`
  - `chat_id`
- **请求体**（代码已确认）：
  - `status=finished`
  - `custom_fields.reason`
  - `custom_fields.open_reservation_again`
- **返回字段**：
  - 代码主要按 HTTP 成功判断
- **鉴权要求**：
  - Bearer + Seiue 业务头
- **来源**：`bdfz/mentee.sh`

---

# 六、学生 / reflection / 搜索 / 资料查询

## 39. `GET https://api.seiue.com/chalk/reflection/students/{student_id}/rid/{reflection_id}?expand=guardians,grade,user`
- **作用**：读取学生详情。
- **方法**：`GET`
- **路径参数**：
  - `student_id`
  - `reflection_id`
- **查询参数**：
  - `expand=guardians,grade,user`
- **返回字段**（代码已用到）：
  - `id`
  - `name`
  - `pinyin`
  - `gender`
  - `usin`
  - `account`
  - `entered_on`
  - `graduation_time`
  - `phone`
  - `email`
  - `grade`
  - `guardians[]`
  - `user`
  - 头像/照片相关字段（用于下载）
- **鉴权要求**：
  - Bearer + Seiue 业务头
- **来源**：
  - `bdfz/seiuestu.sh`
  - `bdfz/seiue-notify.sh`

## 40. `GET https://api.seiue.com/chalk/reflection/students?usin={ident}&paginated=0`
- **作用**：按 usin 查学生。
- **方法**：`GET`
- **查询参数**：
  - `usin={ident}`
  - `paginated=0`
- **返回字段**（代码已用到）：
  - 数组元素首项的 `id`
- **鉴权要求**：
  - Bearer + Seiue 业务头
- **来源**：`bdfz/seiuestu.sh`

## 41. `GET https://api.seiue.com/chalk/search/items?biz_type_in={biz_types}&keyword={keyword}&semester_id={semester_id}`
- **作用**：统一搜索。
- **方法**：`GET`
- **查询参数**：
  - `biz_type_in`
  - `keyword`
  - `semester_id`
- **返回字段**（代码已用到）：
  - 数组元素字段：
    - `biz_type`
    - `biz_id`
    - 其他搜索命中元数据
- **鉴权要求**：
  - Bearer + Seiue 业务头
- **来源**：
  - `bdfz/seiuestu.sh`
  - `bdfz/seiue-notify.sh`

## 42. `GET {SEIUE_BASE}/chalk/group/groups/{group_id}/members?class_id={class_id}&expand=teams,group,reflection,team&paginated=0&sort=member_type_id,-top,reflection.usin`
- **作用**：读取导师组/群组成员。
- **方法**：`GET`
- **路径参数**：
  - `group_id`
- **查询参数**：
  - `class_id`
  - `expand=teams,group,reflection,team`
  - `paginated=0`
  - `sort=member_type_id,-top,reflection.usin`
- **返回字段**（代码已用到）：
  - 数组元素字段：
    - `member_type`
    - `status`
    - `member_id`
    - `reflection`
- **鉴权要求**：
  - Bearer + Seiue 业务头
- **来源**：`bdfz/mentee.sh`

---

# 七、文件 / 网盘 / 图片 / 附件

## 43. `GET https://api.seiue.com/chalk/netdisk/files/{fid}/url`
- **作用**：获取文件签名下载地址。
- **方法**：`GET` 或 `HEAD`（脚本常用 `HEAD` 取 `Location`）
- **路径参数**：
  - `fid`
- **返回字段/响应特征**：
  - 关键不是 JSON，而是响应头 `Location`
  - `Location` 指向实际签名下载 URL
- **鉴权要求**：
  - Bearer + Seiue 业务头
- **来源**：`bdfz/seiue-notify.sh`

## 44. `GET https://api.seiue.com/chalk/netdisk/files/{fid}.jpg/url`
- **作用**：获取图片签名地址。
- **方法**：`GET` / `HEAD`
- **路径参数**：
  - `fid`
- **返回字段/响应特征**：
  - 关键看 `Location`
- **鉴权要求**：
  - Bearer + Seiue 业务头
- **来源**：
  - `bdfz/seiue-notify.sh`
  - `bdfz/seiuestu.sh`

## 45. `GET https://api.seiue.com/chalk/netdisk/files/{fid}.jpg/url?processor=image/resize,w_2048/quality,q_90`
- **作用**：获取处理后的图片链接。
- **方法**：`GET` / `HEAD`
- **路径参数**：
  - `fid`
- **查询参数**：
  - `processor=image/resize,w_2048/quality,q_90`
- **返回字段/响应特征**：
  - 关键看 `Location`
- **鉴权要求**：
  - Bearer + Seiue 业务头
- **来源**：`bdfz/seiuestu.sh`

---

# 八、德育 / 评价 / 发展方向 / 证书

## 46. `GET https://api.seiue.com/scms/direction/owners/{owner_id}/answers`
- **作用**：读取选科/发展方向问卷答案。
- **方法**：`GET`
- **路径参数**：
  - `owner_id`
- **返回字段**：
  - 答案数组/对象
- **鉴权要求**：
  - Bearer + Seiue 业务头
- **来源**：`bdfz/seiuestu.sh`

## 47. `GET https://api.seiue.com/scms/direction/owner/{owner_id}/direction-result?expand=is_guardian_confirmed,confirmed_guardians,confirmed_guardian_ids,subjects_str,setting,owner`
- **作用**：读取选科结果。
- **方法**：`GET`
- **路径参数**：
  - `owner_id`
- **查询参数**：
  - `expand=is_guardian_confirmed,confirmed_guardians,confirmed_guardian_ids,subjects_str,setting,owner`
- **返回字段**（代码/用途可确认）：
  - `is_guardian_confirmed`
  - `confirmed_guardians`
  - `confirmed_guardian_ids`
  - `subjects_str`
  - `setting`
  - `owner`
- **鉴权要求**：
  - Bearer + Seiue 业务头
- **来源**：`bdfz/seiuestu.sh`

## 48. `GET https://api.seiue.com/scms/direction/direction-results/{direction_result_id}/activities?event_action=direction_result.subject_changed&per_page=3`
- **作用**：读取选科活动流。
- **方法**：`GET`
- **路径参数**：
  - `direction_result_id`
- **查询参数**：
  - `event_action=direction_result.subject_changed`
  - `per_page=3`
- **返回字段**：
  - 活动数组
  - 最近变更记录
- **鉴权要求**：
  - Bearer + Seiue 业务头
- **来源**：`bdfz/seiuestu.sh`

## 49. `GET https://api.seiue.com/sgms/certification/reflections/{reflection_id}/cert-school-plugins`
- **作用**：读取学生关联插件/徽章体系。
- **方法**：`GET`
- **路径参数**：
  - `reflection_id`
- **返回字段**（代码/用途可确认）：
  - 数组元素字段：
    - `label`
    - `plugin_id`
- **鉴权要求**：
  - Bearer + Seiue 业务头
- **来源**：`bdfz/seiuestu.sh`

## 50. `GET https://api.seiue.com/sgms/certification/reflections/{reflection_id}/cert-reflections?expand=certification&owner_id={owner_id}&paginated=0&policy=profile_related&sort=-passed_at`
- **作用**：读取证书/认证记录。
- **方法**：`GET`
- **路径参数**：
  - `reflection_id`
- **查询参数**：
  - `expand=certification`
  - `owner_id={owner_id}`
  - `paginated=0`
  - `policy=profile_related`
  - `sort=-passed_at`
- **返回字段**（用途可确认）：
  - 认证记录数组
  - `certification`
  - `passed_at`
- **鉴权要求**：
  - Bearer + Seiue 业务头
- **来源**：`bdfz/seiuestu.sh`

## 51. `GET https://api.seiue.com/chalk/reflection/students/{sid}/rid/{reflection}?expand=guardians,grade,user`
- **作用**：通知侧补学生资料。
- **方法**：`GET`
- **路径参数**：
  - `sid`
  - `reflection`
- **查询参数**：
  - `expand=guardians,grade,user`
- **返回字段**：
  - 与学生详情接口相同，重点用在通知渲染
- **鉴权要求**：
  - Bearer + Seiue 业务头
- **来源**：`bdfz/seiue-notify.sh`

---

# 九、自建中间层 API（不是 Seiue 官方）

## 52. `GET /health`
- **作用**：`kseiue-worker` 健康检查。
- **方法**：`GET`
- **参数**：无
- **返回字段**：
  - 通常为 `status` / 说明文本
- **鉴权要求**：
  - 无
- **来源**：`kseiue-worker/src/index.js`

## 53. `POST /api/report`
- **作用**：自建考勤触发入口，由前端调用，再代理打 Seiue。
- **方法**：`POST`
- **请求体**（代码可确认）：
  - `seiue_username` / `username`
  - `seiue_password` / `password`
  - `date_mode` / `mode`
  - `date`
  - `start_date`
  - `end_date`
- **返回字段**（代码可确认）：
  - `status`
  - `message`
- **鉴权要求**：
  - 无 Seiue Bearer；这是自建服务入口
- **来源**：
  - `kseiue-worker/src/index.js`
  - `my-seiue-app/backend/index.py`

## 54. `POST https://api.seiue.bdfz.net/`
- **作用**：前端提交到自建后端，再由后端代理 Seiue。
- **方法**：`POST`
- **请求体**：
  - 与 `/api/report` 类似的表单/JSON 字段
- **返回字段**：
  - 由自建后端定义，通常含执行状态
- **鉴权要求**：
  - 无 Seiue Bearer；是你自己的中间层入口
- **来源**：`seiue-frontend/index.html`

---

# 十、补充发现的流程 / 请假类接口

## 55. `GET https://api.seiue.com/form/workflow/flows/{flow_id}?expand=initiator,nodes,nodes.stages,nodes.stages.reflection,field_values`
- **作用**：读取请假/流程审批流详情。
- **方法**：`GET`
- **路径参数**：
  - `flow_id`
- **查询参数**：
  - `expand=initiator,nodes,nodes.stages,nodes.stages.reflection,field_values`
- **返回字段**（通知脚本已实际使用/可确认）：
  - `initiator`
  - `nodes`
  - `nodes[].stages`
  - `nodes[].stages[].reflection`
  - `field_values`
- **典型用途**：
  - 在请假通知里补审批流节点、发起人、表单字段、附件。
- **鉴权要求**：
  - Bearer + Seiue 业务头
- **来源**：`bdfz/seiue-notify.sh`

## 56. `GET https://api.seiue.com/sams/absence/absences/{absence_id}?expand=reflections,reflections.guardians,reflections.grade`
- **作用**：读取请假详情。
- **方法**：`GET`
- **路径参数**：
  - `absence_id`
- **查询参数**：
  - `expand=reflections,reflections.guardians,reflections.grade`
- **返回字段**（通知脚本已实际使用/可确认）：
  - `reflections`
  - `reflections[].guardians`
  - `reflections[].grade`
  - 请假对象、时间、原因等 absence 主体字段
- **典型用途**：
  - 在请假通知里补学生、家长、年级、请假主体信息。
- **鉴权要求**：
  - Bearer + Seiue 业务头
- **来源**：`bdfz/seiue-notify.sh`

---

# 十一、最关键的返回字段索引

如果只看当前代码里**真正被消费**的返回字段，优先记这些：

## 认证
- `access_token`
- `active_reflection_id`

## 课程 / 考勤
- `type`
- `custom.id`
- `subject.id`
- `reflection.id`
- `checked_attendance_time_ids`

## 作业 / 批阅 / 成绩
- `id`
- `title`
- `group`
- `assignee`
- `submission`
- `review`
- `related_data.task_id`
- `items`
- `task_relations`
- `score`
- `owner_id`

## 聊天 / 约谈 / 表单
- `members`
- `owner`
- `discussion`
- `chat_form.id`
- `form.id`
- `forms[].id`
- `form_template_fields`
- `form_template_field_id`
- `attributes.attachments`

## 学生 / 搜索 / 选科 / 认证
- `name`
- `usin`
- `grade`
- `guardians`
- `biz_type`
- `biz_id`
- `subjects_str`
- `confirmed_guardian_ids`
- `plugin_id`
- `label`
- `passed_at`

---

# 十二、常见参数约定 / 字段语义

## 1. 头部参数
- `Authorization`: Bearer token
- `x-school-id`: 学校 id，现有代码固定使用 `3`
- `x-role`: 当前角色，现有代码固定使用 `teacher`
- `x-reflection-id`: 当前登录教师 reflection id

## 2. 常见 ID 语义
- `reflection_id`: 反射到 Seiue 人物身份的一层 id，教师/学生都会有
- `owner_id`: 在成绩、方向、评价等场景里常对应学生 owner
- `student_id`: 学生对象 id
- `class_id`: 班级/课程业务 id
- `task_id`: 作业任务 id
- `item_id`: 成绩结构项 id
- `assessment_id`: 评价/成绩结构容器 id
- `flow_id`: 流程审批 id
- `absence_id`: 请假记录 id
- `chat_id`: 约谈/聊天 id
- `instance_id`: chat 实例容器 id

## 3. 常见 expand 语义
- `expand=...` 基本就是要求后端一次性展开关联对象，减少二次请求。
- 当前代码最依赖的 expand：
  - `guardians,grade,user`
  - `items,items.task_relations,items.task_relations.task,klass`
  - `members,owner,discussion,members.reflection,members.reflection.pupil`
  - `form_template_fields`
  - `initiator,nodes,nodes.stages,nodes.stages.reflection,field_values`

---

# 十三、按业务链路整理

## A. 登录 / 换 token 链路
1. `POST /login?school_id=3`
2. `POST /authorize`
3. 提取：
   - `access_token`
   - `active_reflection_id`
4. 后续接口统一附带 Bearer 与业务头

## B. 考勤链路
1. `GET /chalk/calendar/personals/{reflection_id}/events`
2. `GET /sams/attendance/attendances-info`
3. `GET /scms/class/classes/{class_id}/group-members?...`
4. `PUT /sams/attendance/class/{class_id}/records/sync`
5. 再次 `GET /sams/attendance/attendances-info` 回查

## C. 作业 → 批阅 → 写分链路
1. `GET /chalk/task/v2/tasks/{task_id}`
2. `GET /chalk/task/v2/tasks/{task_id}/assignments?...`
3. `GET /vnas/klass/assessments?...` 或多种 `/items?task_id=...` 反查 item
4. `POST /chalk/task/v2/assignees/{receiver_id}/tasks/{task_id}/reviews`
5. `POST /vnas/klass/items/{item_id}/scores/sync?async=true&from_task=true`
6. `GET /vnas/common/items/{item_id}/scores?...` 回查是否写入

## D. 约谈 / 聊天补录链路
1. `GET /chalk/group/groups/{group_id}/members?...`
2. `POST /chalk/chat/instances/{instance_id}/chats`
3. `GET /chalk/chat/instances/{instance_id}/chats/{chat_id}?expand=chat_form,form,forms`
4. `POST /chalk/chat/chats/{chat_id}/chat-form/{template_id}/answers`
5. `PATCH /chalk/chat/instances/{instance_id}/chats/{chat_id}`

## E. 通知 → 详情补全链路
1. `GET /chalk/me/received-messages`
2. 根据通知 domain/type 分流：
   - chat → `/chalk/chat/...`
   - assessment → `/vnas/common/...`
   - leave_flow → `/form/workflow/...` + `/sams/absence/...`
3. 需要头像/附件时，再打学生详情/网盘签名接口

## F. 学生画像链路
1. `GET /chalk/reflection/students?usin=...`
2. `GET /chalk/search/items?...`
3. `GET /chalk/reflection/students/{id}/rid/{reflection_id}?expand=...`
4. `GET /chalk/chat/students/{student_id}/chats?...`
5. `GET /scms/direction/...`
6. `GET /sgms/certification/...`
7. `GET /vnas/klass/owners/{owner_id}/transcript`

---

# 十四、示例请求（按当前代码风格整理）

## 1. 登录
```bash
curl 'https://passport.seiue.com/login?school_id=3' \
  -X POST \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -H 'Origin: https://passport.seiue.com' \
  -H 'Referer: https://passport.seiue.com/login?school_id=3' \
  --data-urlencode 'email=YOUR_USERNAME' \
  --data-urlencode 'password=YOUR_PASSWORD' \
  -c /tmp/seiue.cookies -b /tmp/seiue.cookies
```

## 2. 换 token
```bash
curl 'https://passport.seiue.com/authorize' \
  -X POST \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -H 'Origin: https://chalk-c3.seiue.com' \
  -H 'Referer: https://chalk-c3.seiue.com/' \
  --data-urlencode 'client_id=GpxvnjhVKt56qTmnPWH1sA' \
  --data-urlencode 'response_type=token' \
  -c /tmp/seiue.cookies -b /tmp/seiue.cookies
```

## 3. 查当天课程
```bash
curl 'https://api.seiue.com/chalk/calendar/personals/REFLECTION_ID/events?start_time=2026-04-15%2000:00:00&end_time=2026-04-15%2023:59:59&expand=address,initiators' \
  -H 'Authorization: Bearer YOUR_TOKEN' \
  -H 'x-school-id: 3' \
  -H 'x-role: teacher' \
  -H 'x-reflection-id: REFLECTION_ID'
```

## 4. 提交考勤
```bash
curl 'https://api.seiue.com/sams/attendance/class/CLASS_ID/records/sync' \
  -X PUT \
  -H 'Authorization: Bearer YOUR_TOKEN' \
  -H 'x-school-id: 3' \
  -H 'x-role: teacher' \
  -H 'x-reflection-id: REFLECTION_ID' \
  -H 'Content-Type: application/json' \
  --data '{
    "abnormal_notice_roles": [],
    "attendance_records": [
      {
        "tag": "正常",
        "attendance_time_id": 123456,
        "owner_id": 789012,
        "source": "web"
      }
    ]
  }'
```

## 5. 发 review
```bash
curl 'https://api.seiue.com/chalk/task/v2/assignees/RECEIVER_ID/tasks/TASK_ID/reviews' \
  -X POST \
  -H 'Authorization: Bearer YOUR_TOKEN' \
  -H 'x-school-id: 3' \
  -H 'x-role: teacher' \
  -H 'x-reflection-id: REFLECTION_ID' \
  -H 'Content-Type: application/json' \
  --data '{
    "result": "approved",
    "content": "已阅。",
    "reason": "",
    "attachments": [],
    "do_evaluation": false,
    "is_excellent_submission": false,
    "is_submission_changed": true
  }'
```

## 6. 写分
```bash
curl 'https://api.seiue.com/vnas/klass/items/ITEM_ID/scores/sync?async=true&from_task=true' \
  -X POST \
  -H 'Authorization: Bearer YOUR_TOKEN' \
  -H 'x-school-id: 3' \
  -H 'x-role: teacher' \
  -H 'x-reflection-id: REFLECTION_ID' \
  -H 'Content-Type: application/json' \
  --data '[
    {
      "owner_id": 789012,
      "valid": true,
      "score": "5",
      "review": "完成。",
      "attachments": [],
      "related_data": {"task_id": 636545},
      "type": "item_score",
      "status": "published"
    }
  ]'
```

## 7. 创建约谈
```bash
curl 'https://api.seiue.com/chalk/chat/instances/7/chats' \
  -X POST \
  -H 'Authorization: Bearer YOUR_TOKEN' \
  -H 'x-school-id: 3' \
  -H 'x-role: teacher' \
  -H 'x-reflection-id: REFLECTION_ID' \
  -H 'Content-Type: application/json' \
  --data '{
    "title": "約談補錄",
    "content": "系統自動補錄的約談記錄。",
    "attachments": [],
    "member_ids": [REFLECTION_ID, STUDENT_REFLECTION_ID],
    "place_name": "辦公室",
    "start_time": "2026-04-15 09:00:00",
    "end_time": "2026-04-15 09:10:00",
    "custom_fields": {
      "chat_method": "offline",
      "is_classin": false,
      "chat_type": "chat"
    }
  }'
```

---

# 十五、示例响应骨架（只保留代码真正关心的字段）

## 1. `/authorize`
```json
{
  "access_token": "...",
  "active_reflection_id": 123456
}
```

## 2. `/chalk/calendar/personals/{reflection_id}/events`
```json
[
  {
    "type": "lesson",
    "title": "语文",
    "custom": {"id": 123456},
    "subject": {"id": 1815547}
  }
]
```

## 3. `/scms/class/classes/{class_id}/group-members?...`
```json
[
  {
    "reflection": {"id": 789012}
  }
]
```

## 4. `/sams/attendance/attendances-info`
```json
[
  {
    "checked_attendance_time_ids": [123456, 123457]
  }
]
```

## 5. `/chalk/task/v2/tasks/{task_id}/assignments?...`
```json
[
  {
    "assignee": {},
    "submission": {},
    "review": {},
    "team": {},
    "is_excellent": false
  }
]
```

## 6. `/vnas/klass/items/{item_id}?expand=...`
```json
{
  "id": 1679605,
  "related_data": {"task_id": 636545},
  "assessment": {},
  "assessment_stage": {},
  "stage": {}
}
```

## 7. `/chalk/reflection/students/{student_id}/rid/{reflection_id}?expand=...`
```json
{
  "id": 10001,
  "name": "某学生",
  "usin": "20260101",
  "grade": {},
  "guardians": [],
  "user": {}
}
```

---

# 十六、常见失败码 / 重试经验

## 认证类
- `401/403`
  - token 过期或 reflection/header 不匹配
  - 现有脚本普遍策略：**重新登录一次再重试**

## 考勤类
- `409/422`
  - 常见表示时间窗口关闭、状态冲突、业务规则不允许
- 处理建议：
  - 先查 `attendances-info`
  - 再确认 lesson 的 `custom.id` 与 `subject.id`

## 作业 / 写分类
- `404`
  - 常见是 `item_id` 不存在 / 已删 / 不匹配
- `422`
  - 常见是：
    - 分数超上限
    - item/task 不匹配
    - 记录已存在
- 处理建议：
  1. 重新解析 `task_id -> item_id`
  2. 必要时先 `get_item_detail()` 验证 `related_data.task_id`
  3. 写分后用 `/vnas/common/items/{item_id}/scores?...` 回查

## 网盘签名类
- `401/403`
  - token 失效，重登即可
- `302`
  - 正常，不是错误；关键看 `Location`

## 约谈 / 表单类
- 创建 chat 成功但找不到 form_id
  - 先查 `custom_fields.form_id`
  - 再查 `chat_form.id`
  - 再查 `form.id`
  - 最后查 `forms[].id`

---

# 十七、接口覆盖边界说明

这份文档当前已经补到：
- 代码里直接出现的接口
- 运行链路里已被长期验证过的核心接口
- 通知侧顺藤摸瓜拉到的关联接口
- 自建中间层接口

但**仍不等于**：
- Seiue 官方全站完整 OpenAPI
- 所有角色（教师/学生/家长/管理员）全量接口面
- 所有 query/body 字段的严格 schema

准确说，它现在是：

> **你现有代码生态下，足够支撑考勤、作业、评分、通知、约谈、学生画像、请假流这些自动化任务的“最大实用版 API 文档”。**

---

# 十八、来源仓库 / 文件

主要来源：

- `~/Desktop/CF/kseiue-worker/src/index.js`
- `~/Desktop/CF/my-seiue-app/backend/index.py`
- `~/Desktop/CF/bdfz/agrader.sh`
- `~/Desktop/CF/bdfz/seiue-notify.sh`
- `~/Desktop/CF/bdfz/seiuestu.sh`
- `~/Desktop/CF/bdfz/mentee.sh`
- `~/Desktop/CF/seiue-frontend/index.html`
- 历史已验证的 Seiue 自动化链路

---

# 十九、结论

现在这份已经不是“接口名罗列版”，而是接近 runbook 的版本：

- **方法**：有了
- **关键参数**：有了
- **代码确认过的返回字段**：有了
- **鉴权要求**：有了
- **业务链路**：有了
- **示例请求**：有了
- **响应骨架**：有了
- **失败码/重试经验**：有了

如果还要继续往死里补，下一层应该是：
1. 每个接口补真实抓包样例
2. 每个链路单独拆成 runbook
3. 生成 task→item→assessment、message→chat/form、leave_flow→absence 的关系图
4. 最后再抽一份真正适合程序消费的 machine-readable schema
