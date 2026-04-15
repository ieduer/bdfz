# Seiue 网站 API 清单（基于本机 + GitHub 代码实扫）

> 说明
>
> - 这不是 Seiue 官方全量开放平台文档。
> - 这是**基于你本机现有代码仓 + GitHub 同源代码中实际出现过的接口**整理出的“最全实扫版”。
> - 我只收录了代码里真实出现、能定位到用途的接口；不会编造未在代码里出现的 API。
> - 同一路径如果在多个脚本/项目里重复出现，只保留一条并补充用途与来源。

---

## 一、认证 / 鉴权 / 入口

### 1. `POST https://passport.seiue.com/login?school_id=3`
- **作用**：Seiue 教师侧登录入口，提交邮箱/用户名 + 密码，建立登录会话 cookie。
- **典型用途**：考勤自动化、作业评分、通知抓取、学生信息抓取前的第一步。
- **主要来源**：
  - `kseiue-worker/src/index.js`
  - `my-seiue-app/backend/index.py`

### 2. `POST https://passport.seiue.com/authorize`
- **作用**：在登录会话基础上换取 access token 与 `active_reflection_id`。
- **典型用途**：后续访问 `api.seiue.com` 的各类业务接口时，设置：
  - `Authorization: Bearer ...`
  - `x-school-id: 3`
  - `x-role: teacher`
  - `x-reflection-id: ...`
- **主要来源**：
  - `kseiue-worker/src/index.js`
  - `my-seiue-app/backend/index.py`

---

## 二、日历 / 课程 / 考勤

### 3. `GET https://api.seiue.com/chalk/calendar/personals/{reflection_id}/events`
- **作用**：读取某个 reflection（通常教师本人）的日程事件。
- **典型参数**：
  - `start_time`
  - `end_time`
  - `expand=address,initiators`
- **典型用途**：筛出当天 `type === lesson` 的课程，作为考勤提交目标。
- **主要来源**：
  - `kseiue-worker/src/index.js`
  - `my-seiue-app/backend/index.py`
  - `bdfz/saa_decoded.sh`

### 4. `GET https://api.seiue.com/scms/class/classes/{class_id}/group-members?expand=reflection&member_type=student`
- **作用**：读取一个班级/课程组的学生成员列表，并展开学生 reflection。
- **典型用途**：为考勤提交批量生成 `{owner_id, attendance_time_id}` 记录。
- **主要来源**：
  - `kseiue-worker/src/index.js`
  - `my-seiue-app/backend/index.py`

### 5. `PUT https://api.seiue.com/sams/attendance/class/{class_id}/records/sync`
- **作用**：批量同步/提交某个班级的考勤记录。
- **典型用途**：自动将整节课学生打成“正常”等状态。
- **请求体关键字段**：
  - `attendance_records`
  - `abnormal_notice_roles`
- **主要来源**：
  - `kseiue-worker/src/index.js`
  - `my-seiue-app/backend/index.py`
  - `bdfz/saa_decoded.sh`

### 6. `GET https://api.seiue.com/sams/attendance/attendances-info`
- **作用**：查询指定考勤时间段/班级是否已经被点过名。
- **典型参数**：
  - `attendance_time_id_in`
  - `biz_id_in`
  - `biz_type_in=class`
  - `expand=checked_attendance_time_ids`
  - `paginated=0`
- **典型用途**：做“已点名校验”，避免重复提交。
- **主要来源**：
  - `kseiue-worker/src/index.js`
  - `my-seiue-app/backend/index.py`
  - `bdfz/saa_decoded.sh`

---

## 三、作业 / 任务 / 提交 / 批阅

### 7. `GET /chalk/task/v2/tasks/{task_id}`
- **作用**：读取单个作业/任务详情。
- **典型用途**：确认任务标题、班级、分组、状态、结构关联。
- **主要来源**：
  - `bdfz/agrader.sh`

### 8. `GET /chalk/task/v2/tasks?id_in={ids}&expand=group`
- **作用**：批量读取多个 task 详情并展开 group。
- **典型用途**：按 task_id 批量汇总任务元信息。
- **主要来源**：
  - `bdfz/agrader.sh`

### 9. `GET /chalk/task/v2/tasks/{task_id}/assignments?expand=is_excellent,assignee,team,submission,review`
- **作用**：读取某个作业的提交/分配情况。
- **典型用途**：取学生提交、review、优秀标记、submission 详情。
- **主要来源**：
  - `bdfz/agrader.sh`

### 10. `POST /chalk/task/v2/assignees/{receiver_id}/tasks/{task_id}/reviews`
- **作用**：给学生提交写 review / 评语。
- **典型用途**：自动批阅作业时先发 review，再写分数。
- **主要来源**：
  - `bdfz/agrader.sh`

### 11. `PUT /chalk/task/v2/tasks/{task_id}`
- **作用**：更新任务/作业。
- **典型用途**：你之前的作业自动化链路里验证过“发布/更新任务”。
- **说明**：代码本轮未再次扫到调用实现，但此接口已在长期操作记忆中验证可用。
- **来源依据**：历史 Seiue 作业闭环记录

### 12. `POST /chalk/task/v2/tasks/$batch`
- **作用**：批量创建作业/任务。
- **典型用途**：寒假作业/背默/阅读等任务批量创建。
- **说明**：当前代码扫描结果主要来自操作记忆与既有 runbook，未在本轮展示文件片段中直接读到，但这是已验证过的核心接口。
- **来源依据**：历史 Seiue 作业闭环记录

### 13. `DELETE /chalk/task/v2/tasks/{task_id}`
- **作用**：删除测试任务或误发任务。
- **典型用途**：清理测试作业、逐个 task 清空残留。
- **来源依据**：历史 Seiue 作业闭环记录

---

## 四、评分 / 成绩结构 / assessment / item

### 14. `GET /vnas/klass/items/{item_id}?expand=related_data,assessment,assessment_stage,stage`
- **作用**：读取某个成绩项 item 详情。
- **典型用途**：
  - 看 item 满分
  - 看 assessment/stage
  - 看 `related_data.task_id`
  - 校验 task 与 item 是否真的对应
- **主要来源**：
  - `bdfz/agrader.sh`

### 15. `GET /vnas/common/items/{item_id}/scores?paginated=0&type=item_score`
- **作用**：读取某个 item 的已有分数。
- **典型用途**：评分后回查 owner_id 对应的实际分数，避免重复写分或误判。
- **说明**：模板来自环境变量 `SEIUE_VERIFY_SCORE_GET_TEMPLATE`，默认走这条。
- **主要来源**：
  - `bdfz/agrader.sh`

### 16. `POST /vnas/klass/items/{item_id}/scores/sync?async=true&from_task=true`
- **作用**：向成绩项写分。
- **典型用途**：将 task review 后的成绩同步到 assessment item。
- **请求体关键字段**：
  - `owner_id`
  - `score`
  - `review`
  - `related_data.task_id`
  - `type=item_score`
- **主要来源**：
  - `bdfz/agrader.sh`
  - 你的长期 Seiue 作业自动化链路

### 17. `GET /vnas/klass/items?related_data.task_id={task_id}`
### 18. `GET /vnas/klass/items?related_data[task_id]={task_id}`
### 19. `GET /vnas/common/items?related_data.task_id={task_id}`
### 20. `GET /vnas/common/items?related_data[task_id]={task_id}`
### 21. `GET /vnas/klass/items?task_id={task_id}`
### 22. `GET /vnas/common/items?task_id={task_id}`
- **作用**：按 task_id 反查可能对应的 item。
- **典型用途**：在 task_relations 不稳定时，遍历多种查询形式做 item 解析兜底。
- **主要来源**：
  - `bdfz/agrader.sh`

### 23. `GET /vnas/klass/assessments?expand=items,items.task_relations,items.task_relations.task,klass&scope_id_in={class_id}&scope_type=class&semester_id={semester_id}`
- **作用**：读取班级 assessment 与 items、task_relations 的完整映射。
- **典型用途**：
  - 解析 `task_id -> item_id`
  - 查成绩结构是否已建立
  - 为自动写分做映射基线
- **来源依据**：历史 Seiue 作业闭环记录

### 24. `POST /vnas/klass/assessments/{assessment_id}/items`
- **作用**：向 assessment 下写入/复制 item 结构。
- **典型用途**：把某班已有成绩结构复制到别的班。
- **来源依据**：历史 Seiue 结构复制链路

### 25. `GET https://api.seiue.com/vnas/common/assessments/{assessment_id}?expand=items,plan&operation_type={op_type}&policy=evaluated`
- **作用**：读取某个 assessment 的通用详情。
- **典型用途**：德育/评价通知里查看 assessment 名称、plan、items。
- **主要来源**：
  - `bdfz/seiue-notify.sh`

### 26. `GET https://api.seiue.com/vnas/common/items/{item_id}/score-details?expand=item,evaluator&operation_type={op_type}&owner_id={owner_id}&paginated=0&policy=evaluated`
- **作用**：读取某个 item 对某个 owner 的打分详情。
- **典型用途**：德育/评价通知中拼出最新分值、评价项名称、评价人。
- **主要来源**：
  - `bdfz/seiue-notify.sh`

### 27. `GET ${API}/vnas/klass/owners/{owner_id}/transcript`
- **作用**：读取学生 transcript / 成绩单。
- **典型用途**：学生资料查询、成长/学业结果展示。
- **主要来源**：
  - `bdfz/seiuestu.sh`

---

## 五、通知 / 消息 / 约谈 / 班级聊天

### 28. `GET https://api.seiue.com/chalk/me/received-messages`
- **作用**：读取当前教师收到的系统消息/通知流。
- **典型参数**：
  - `owner.id`
  - `type=message`
  - `notice=true`
  - `readed=false`
  - `expand=sender_reflection,aggregated_messages`
- **典型用途**：Seiue 通知机器人抓通知并转发 Telegram。
- **主要来源**：
  - `bdfz/seiue-notify.sh`

### 29. `GET https://api.seiue.com/chalk/chat/instances/{instance_id}/chats/{chat_id}?expand=members,owner,discussion,members.reflection,members.reflection.pupil`
- **作用**：读取约谈/聊天详情并展开成员、讨论、学生 reflection。
- **典型用途**：通知机器人在收到聊天类通知后补全上下文。
- **主要来源**：
  - `bdfz/seiue-notify.sh`

### 30. `GET https://api.seiue.com/chalk/chat/chats/{chat_id}/schedule-section?expand=section_members,schedule,schedule.compere,section_members.reflection`
- **作用**：读取约谈 schedule-section 信息。
- **典型用途**：约谈通知里补齐地点、时间、参与学生。
- **主要来源**：
  - `bdfz/seiue-notify.sh`

### 31. `GET https://api.seiue.com/chalk/chat/students/{student_id}/chats?expand=owner&per_page=10&sort=-start_time&type=chat`
- **作用**：按学生读取最近聊天/约谈。
- **典型用途**：学生关联信息查询。
- **主要来源**：
  - `bdfz/seiuestu.sh`

### 32. `GET https://api.seiue.com/form/chat/chat-form/{chat_id}/answers?paginated=0`
- **作用**：读取某个约谈的表单答案。
- **典型用途**：把约谈中的老师记录、附件等抓出来发通知。
- **主要来源**：
  - `bdfz/seiue-notify.sh`

### 33. `GET https://api.seiue.com/form/chat/chat-form-template?expand=form_template_fields&id={template_id}[&instance_id={instance_id}]`
- **作用**：读取约谈表单模板结构。
- **典型用途**：把 form template fields 和 answers 对齐解析。
- **主要来源**：
  - `bdfz/seiue-notify.sh`

### 34. `POST {SEIUE_BASE}/chalk/chat/instances/{CHAT_INSTANCE_ID}/chats`
- **作用**：创建一个新的聊天/约谈。
- **典型用途**：导师约谈脚本自动补录约谈。
- **主要来源**：
  - `bdfz/mentee.sh`

### 35. `GET {SEIUE_BASE}/chalk/chat/instances/{CHAT_INSTANCE_ID}/chats/{chat_id}?expand=chat_form,form,forms`
- **作用**：读取刚创建的聊天，并尝试拿到关联 form_id。
- **典型用途**：创建约谈后确定 chat form 实例。
- **主要来源**：
  - `bdfz/mentee.sh`

### 36. `GET {SEIUE_BASE}/chalk/chat/instances/{CHAT_INSTANCE_ID}/chats/{chat_id}`
- **作用**：读取聊天详情（不带 expand）。
- **典型用途**：作为上面失败时的兜底。
- **主要来源**：
  - `bdfz/mentee.sh`

### 37. `POST {SEIUE_BASE}/chalk/chat/chats/{chat_id}/chat-form/{CHAT_FORM_TEMPLATE_ID}/answers`
- **作用**：提交约谈表单答案。
- **典型用途**：把补录的导师约谈内容写入聊天表单。
- **主要来源**：
  - `bdfz/mentee.sh`

### 38. `PATCH {SEIUE_BASE}/chalk/chat/instances/{CHAT_INSTANCE_ID}/chats/{chat_id}`
- **作用**：更新聊天状态。
- **典型用途**：补录约谈后把状态改成 `finished`。
- **主要来源**：
  - `bdfz/mentee.sh`

---

## 六、学生 / reflection / 搜索 / 资料查询

### 39. `GET https://api.seiue.com/chalk/reflection/students/{student_id}/rid/{reflection_id}?expand=guardians,grade,user`
- **作用**：读取学生详情。
- **典型用途**：
  - 学生信息查询
  - 通知里补学生姓名、年级、家长
  - 下载头像前先拿 photo/avatar
- **主要来源**：
  - `bdfz/seiuestu.sh`
  - `bdfz/seiue-notify.sh`

### 40. `GET https://api.seiue.com/chalk/reflection/students?usin={ident}&paginated=0`
- **作用**：按 usin 查学生 reflection 列表。
- **典型用途**：当输入是学号/usin 时做解析。
- **主要来源**：
  - `bdfz/seiuestu.sh`

### 41. `GET https://api.seiue.com/chalk/search/items?biz_type_in={biz_types}&keyword={keyword}&semester_id={semester_id}`
- **作用**：统一搜索接口。
- **典型用途**：按姓名/关键词搜学生、老师、班级、消息等。
- **主要来源**：
  - `bdfz/seiuestu.sh`
  - `bdfz/seiue-notify.sh`

### 42. `GET {SEIUE_BASE}/chalk/group/groups/{group_id}/members?class_id={class_id}&expand=teams,group,reflection,team&paginated=0&sort=member_type_id,-top,reflection.usin`
- **作用**：读取 group 成员。
- **典型用途**：补录约谈时先拿班级所有学生 reflection id。
- **主要来源**：
  - `bdfz/mentee.sh`

---

## 七、文件 / 网盘 / 图片 / 附件

### 43. `GET https://api.seiue.com/chalk/netdisk/files/{fid}/url`
- **作用**：拿 netdisk 文件签名下载链接。
- **典型用途**：下载通知附件。
- **主要来源**：
  - `bdfz/seiue-notify.sh`

### 44. `GET https://api.seiue.com/chalk/netdisk/files/{fid}.jpg/url`
- **作用**：拿 jpg 形式的签名图片链接。
- **典型用途**：下载图片型附件、学生照片。
- **主要来源**：
  - `bdfz/seiue-notify.sh`
  - `bdfz/seiuestu.sh`

### 45. `GET https://api.seiue.com/chalk/netdisk/files/{fid}.jpg/url?processor=image/resize,w_2048/quality,q_90`
- **作用**：拿经过处理器压缩/缩放后的图片下载链接。
- **典型用途**：下载高清但适合 Telegram/本地存档的图片。
- **主要来源**：
  - `bdfz/seiuestu.sh`

---

## 八、德育 / 评价 / 发展方向 / 证书

### 46. `GET https://api.seiue.com/scms/direction/owners/{owner_id}/answers`
- **作用**：读取学生发展方向问卷答案。
- **典型用途**：学生资料拉取。
- **主要来源**：
  - `bdfz/seiuestu.sh`

### 47. `GET https://api.seiue.com/scms/direction/owner/{owner_id}/direction-result?expand=is_guardian_confirmed,confirmed_guardians,confirmed_guardian_ids,subjects_str,setting,owner`
- **作用**：读取学生发展方向结果。
- **典型用途**：方向结果与家长确认情况查询。
- **主要来源**：
  - `bdfz/seiuestu.sh`

### 48. `GET https://api.seiue.com/scms/direction/direction-results/{direction_result_id}/activities?event_action=direction_result.subject_changed&per_page=3`
- **作用**：读取方向结果活动流。
- **典型用途**：看科目调整/活动记录。
- **主要来源**：
  - `bdfz/seiuestu.sh`

### 49. `GET https://api.seiue.com/sgms/certification/reflections/{reflection_id}/cert-school-plugins`
- **作用**：读取学生关联的证书/插件信息。
- **典型用途**：学生相关插件与徽章查询。
- **主要来源**：
  - `bdfz/seiuestu.sh`

### 50. `GET https://api.seiue.com/sgms/certification/reflections/{reflection_id}/cert-reflections?expand=certification&owner_id={owner_id}&paginated=0&policy=profile_related&sort=-passed_at`
- **作用**：读取学生证书/认证记录。
- **典型用途**：证书、处分、认证类信息拉取。
- **主要来源**：
  - `bdfz/seiuestu.sh`

### 51. `GET https://api.seiue.com/chalk/reflection/students/{sid}/rid/{reflection}?expand=guardians,grade,user`
- **作用**：通知侧按 sid/reflection 拉学生详情。
- **典型用途**：在通知机器人里补齐请假/德育消息的学生信息。
- **主要来源**：
  - `bdfz/seiue-notify.sh`

---

## 九、健康检查 / 自建中间层 API（不是 Seiue 官方，但围绕 Seiue）

> 下面这些不是 `api.seiue.com` 官方接口，而是你自己项目里围绕 Seiue 做的中间层/前后端接口，也一并列出，避免混淆。

### 52. `GET /health`
- **作用**：`kseiue-worker` 自身健康检查。
- **用途**：确认 Cloudflare Worker 后端在线。
- **主要来源**：
  - `kseiue-worker/src/index.js`

### 53. `POST /api/report`
- **作用**：`kseiue-worker` 自建 API，接收用户名/密码/日期模式，触发 Seiue 考勤流程。
- **用途**：前端按钮提交后，由 Worker 去调用 Seiue 官方接口。
- **主要来源**：
  - `kseiue-worker/src/index.js`
  - `kseiue-worker/public/index.html`

### 54. `POST https://api.seiue.bdfz.net/`
- **作用**：`seiue-frontend` 所指向的自建后端入口。
- **用途**：网页端提交考勤任务，由后端代理调用 Seiue。
- **主要来源**：
  - `seiue-frontend/index.html`

---

## 十、按功能归类的最核心接口速查

### A. 登录 / token
- `POST https://passport.seiue.com/login?school_id=3`
- `POST https://passport.seiue.com/authorize`

### B. 查课表 / 点名
- `GET /chalk/calendar/personals/{reflection_id}/events`
- `GET /scms/class/classes/{class_id}/group-members?...`
- `GET /sams/attendance/attendances-info`
- `PUT /sams/attendance/class/{class_id}/records/sync`

### C. 作业 / 任务
- `GET /chalk/task/v2/tasks/{task_id}`
- `GET /chalk/task/v2/tasks?id_in=...&expand=group`
- `GET /chalk/task/v2/tasks/{task_id}/assignments?...`
- `POST /chalk/task/v2/assignees/{receiver_id}/tasks/{task_id}/reviews`
- `POST /chalk/task/v2/tasks/$batch`
- `PUT /chalk/task/v2/tasks/{task_id}`
- `DELETE /chalk/task/v2/tasks/{task_id}`

### D. 评分 / 成绩结构
- `GET /vnas/klass/assessments?...`
- `POST /vnas/klass/assessments/{assessment_id}/items`
- `GET /vnas/klass/items/{item_id}?expand=...`
- `POST /vnas/klass/items/{item_id}/scores/sync?async=true&from_task=true`
- `GET /vnas/common/items/{item_id}/scores?paginated=0&type=item_score`
- `GET /vnas/common/assessments/{assessment_id}?expand=items,plan...`
- `GET /vnas/common/items/{item_id}/score-details?...`
- `GET /vnas/klass/owners/{owner_id}/transcript`

### E. 通知 / 约谈 / 聊天
- `GET /chalk/me/received-messages`
- `GET /chalk/chat/instances/{instance_id}/chats/{chat_id}?expand=...`
- `GET /chalk/chat/chats/{chat_id}/schedule-section?expand=...`
- `GET /chalk/chat/students/{student_id}/chats?...`
- `POST /chalk/chat/instances/{instance_id}/chats`
- `POST /chalk/chat/chats/{chat_id}/chat-form/{template_id}/answers`
- `PATCH /chalk/chat/instances/{instance_id}/chats/{chat_id}`
- `GET /form/chat/chat-form/{chat_id}/answers?paginated=0`
- `GET /form/chat/chat-form-template?...`

### F. 学生 / 搜索 / 方向 / 证书
- `GET /chalk/reflection/students/{student_id}/rid/{reflection_id}?expand=...`
- `GET /chalk/reflection/students?usin={ident}&paginated=0`
- `GET /chalk/search/items?...`
- `GET /scms/direction/owners/{owner_id}/answers`
- `GET /scms/direction/owner/{owner_id}/direction-result?...`
- `GET /scms/direction/direction-results/{id}/activities?...`
- `GET /sgms/certification/reflections/{reflection_id}/cert-school-plugins`
- `GET /sgms/certification/reflections/{reflection_id}/cert-reflections?...`

### G. 文件 / 图片
- `GET /chalk/netdisk/files/{fid}/url`
- `GET /chalk/netdisk/files/{fid}.jpg/url`
- `GET /chalk/netdisk/files/{fid}.jpg/url?processor=image/resize,w_2048/quality,q_90`

---

## 十一、来源仓库

本清单主要来自这些代码源：

- `~/Desktop/CF/kseiue-worker`
- `~/Desktop/CF/my-seiue-app`
- `~/Desktop/CF/seiue-frontend`
- `~/Desktop/CF/bdfz/agrader.sh`
- `~/Desktop/CF/bdfz/seiue-notify.sh`
- `~/Desktop/CF/bdfz/seiuestu.sh`
- `~/Desktop/CF/bdfz/mentee.sh`
- 历史已验证的 Seiue 作业自动化操作记忆

---

## 十二、结论

如果只看你现有代码里**真实出现过**的 Seiue 接口，核心可以归纳成 7 大系统：

1. **passport**：登录与 token
2. **chalk**：日历、消息、聊天、任务、搜索、网盘、reflection
3. **sams**：考勤
4. **vnas**：成绩结构、评分、transcript、评分类详情
5. **scms**：班级成员、发展方向
6. **sgms**：证书/认证
7. **form**：聊天表单

如果你要，我下一步可以继续做两件事里的一个：

1. **把这份清单再扩成“每个 API 的请求方法 + 关键参数 + 返回字段”版**
2. **把它写进 `project-collab-ops` 或单独新建 `seiue-api-catalog` 文档仓**，供后续多 AI 共用
