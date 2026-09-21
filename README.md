# 选课指南 · Discourse 原生插件

Rails / PostgreSQL 后端与原生 Glimmer 页面，入口 `/courses`。日常运行无需旧 Next.js 服务。课程与导师保留独立目录、评分和讨论；评价不转换成普通论坛帖子。

当前阶段：已完成真实数据迁移与正式上线。入口为 [river-side.cc/courses](https://river-side.cc/courses)，与校友地图共用“校园生活”侧栏分组；旧 review.river-side.cc 链接跳转到对应原生页面。首次发布代码提交为 `bb7a1e15c21dd1562b2d3267a54daa40393b9e88`。

## 配置

验证环境为 Discourse `2026.9.0-latest` / `5b59681a8`，不承诺其他版本。安装到 `plugins/discourse-course-review` 后运行 migrations，并依次构建插件 JavaScript 和预编译资源，重启应用。

- `courses_enabled`：默认关闭。
- `courses_allowed_groups`：可访问成员组；留空仅管理员可用。
- `courses_admin_groups`：本应用管理员组。论坛管理员始终有权限。
- `courses_read_only`：禁止所有业务写入与通知补发，适合真实数据预览。

安装校友地图的共同导航组件后，入口自动加入“校园生活”，不新增单独分组。仅课程插件单独安装时保留独立侧栏入口。

## 迁移与验证

[旧新版差异、数据对账及测试说明](docs/parity-review.md)。

- `script/export_legacy.mjs`：旧库只读、RepeatableRead 导出，必须显式提供 `LEGACY_DATABASE_URL`，不读取 `.env`。
- `script/import_legacy.rb FILE`：默认事务回滚演练；正式导入需要插件关闭、业务表为空、`RIVER_IMPORT_APPLY=1` 和匹配的 `RIVER_IMPORT_SHA256`。仅同一 SHA 可幂等重复，不支持用新快照覆盖已有业务。
- `script/verify_legacy.rb FILE`：只读逐字段检查目录、评价、回复关系、赞踩、收藏、归属、匿名、隐藏状态及时间戳。应在允许新写入前运行。
- `test/parity_test.rb`：只允许指定的一次性隔离数据库，覆盖业务、权限、匿名、生命周期和目录更新。

保留原始 Legacy 记录供核对，普通业务接口不会暴露这些归档。个人导出 `/courses/export` 只包含本人数据。删除/匿名化会清理相关业务与导入归档；用户合并保留目标账号的冲突评价，非冲突内容转移后以匿名方式展示。

## 后续目录维护

课程 Excel 与导师页面抓取原本就是命令行工具，本插件保留该工作方式，改为“生成目录文件 → Rails 事务校验 → 确认导入”，不再依赖旧业务数据库。

```sh
# DEPENDENCIES_DIR 中安装 read-excel-file（9.x）和 cheerio；现有旧项目依赖也可复用。
node script/catalog-courses.mjs DEPENDENCIES_DIR 教学任务列表.xlsx /private/catalog.json
node script/catalog-mentors.mjs DEPENDENCIES_DIR /private/mentors.json --limit=10

# 指定真实管理员，默认回滚演练。
COURSES_CATALOG_ACTOR_ID=123 RAILS_ENV=production bundle exec rails runner plugins/discourse-course-review/script/import_catalog.rb /private/catalog.json
```

确认结果后，先开启 `courses_read_only`，再使用 `COURSES_CATALOG_APPLY=1`、`COURSES_CATALOG_SHA256=<核对的 SHA>` 和同一管理员执行。按“课程序号+学期”或导师来源编号更新，保留评价与讨论关联，不删除目录中未出现的对象。Excel 使用旧工具相同的工作簿读取库；不支持 Excel 97 二进制格式的伪装输入。

通知使用原生铃铛并链接到讨论；不发送历史通知、邮件或私聊。举报在插件自己的管理页处理，尚未接入全站 Reviewable 队列。停用或卸载插件不会自动删除业务表。

最新功能核对和历史链接修补见 [最终复核](docs/final-review.md)。
