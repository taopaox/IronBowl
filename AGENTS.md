# 开发规则

## 开发完成后本地构建并打开应用

每次完成代码开发并验证测试通过后，自动构建到 `build/DerivedData` 并重启打开本地应用：

```bash
xcodebuild -project IronBowl.xcodeproj -scheme IronBowl -configuration Debug -derivedDataPath build/DerivedData build
(pkill -x IronBowl || true) && sleep 0.5 && open build/DerivedData/Build/Products/Debug/IronBowl.app
```

- 如果本次改动涉及独立版万年历（`Apps/Calendar`），同步构建并打开 `Calendar` scheme（`build/DerivedData/Build/Products/Debug/IronBowlCalendar.app`）：

```bash
xcodebuild -project IronBowl.xcodeproj -scheme Calendar -configuration Debug -derivedDataPath build/DerivedData build
(pkill -x IronBowlCalendar || true) && sleep 0.5 && open build/DerivedData/Build/Products/Debug/IronBowlCalendar.app
```

## 项目文档规范（docs 目录）

- 所有项目文档统一存放在 `docs/` 目录下，并按领域分目录组织，由 `docs/README.md` 作为总索引（保留历史设计清单 `docs/DESIGN.md`）：
  - `docs/architecture/`：整体架构、插件机制、数据存储与迁移、视觉设计系统
  - `docs/core/`：`IronBowlKit` 公共底座能力（AI 提供者、工作日历、网页墓碑、提醒中心等）
  - `docs/plugins/`：各业务插件文档（禅道日志、万年历、飞书知识库、AI 目录等）
  - `docs/apps/`：可执行应用宿主说明（工作台 `IronBowl`、独立版万年历 `IronBowlCalendar`）
  - `docs/development/`：环境搭建、构建测试与插件开发指南
- 随着功能演进新增子领域时，可在 `docs/` 下继续按目录拆分并同步更新 `docs/README.md`。
- 每次新增或修改功能、插件行为、数据库迁移、设置键（`SettingKey`）、项目结构或构建/测试流程时，必须同步更新 `docs/` 下对应的文档；新增或调整文档目录时同步更新 `docs/README.md` 索引。
- 文档内容必须与真实代码一致，仅记录实际存在的源码路径、符号名、表名、设置键和命令，不写推测或过时内容。

## Git 分支规范

- **`main` 分支仅限合并或 PR**：`main` 为受保护发布分支，**严禁在 `main` 分支上直接开发、直接 `git commit` 或直接推送普通开发提交**，仅允许通过 GitHub Pull Request 或从 `dev` 分支合并进入。
- **日常在 `dev` 分支开发**：所有新功能开发与缺陷修复均在 `dev` 分支（或从 `dev` 切出的 `feat/*`、`fix/*` 分支）完成，验证通过后合入 `dev`，再由 `dev` 向 `main` 发起 PR 或合并，合并后自动触发 GitHub Actions 编译与发版。
- **启用本地分支保护钩子**：仓库在 `.githooks/` 下提供 `pre-commit` 与 `pre-push` 拦截脚本，克隆或初始化工作区后确保执行：
  ```bash
  git config core.hooksPath .githooks
  ```

## Git 提交规范

- 开发一个功能提交一次：每完成一个独立功能（或一次独立修复）并验证构建与测试通过、同步更新相关文档后，立即执行一次独立的 `git commit`，避免将多个不相关的功能改动混在同一次提交中。
- 提交前检查 `git status` 与 `git diff`，仅暂存本次功能相关文件，不提交无关改动；除非明确要求，否则仅本地提交，不自动执行 `git push`。

## Git 提交说明规则

每条提交说明都要按下面的格式写：

- 第一行格式为 `类型(范围): 中文描述`，范围可省略，例如 `feat(people): 人物页新增生日提醒`、`fix: 生日为空时不显示提醒`。
- 描述用中文写清楚改了什么、对使用者有什么变化，不写“修改代码”“更新”这类空泛说法；一条提交只做一类事。
- 类型只用下表这些，决定它在更新记录里归入哪一组：

| 类型                   | 更新记录分组 | 用于                           |
| ---------------------- | ------------ | ------------------------------ |
| `feat`                 | 新功能       | 新增功能或使用者可见的新行为   |
| `fix`                  | 修复         | 修复缺陷                       |
| `perf`                 | 性能         | 性能改进                       |
| `refactor`             | 重构         | 不改变行为的代码调整           |
| `docs`                 | 文档         | 只改文档                       |
| `test`                 | 测试         | 只改测试                       |
| `build`、`ci`、`chore` | 构建与维护   | 打包、依赖、工作流、发布脚本等 |

- 破坏性变更（使用者需要调整用法或配置）在类型后加 `!`，如 `feat!: …`，或在正文写 `BREAKING CHANGE: 说明`；发版时次版本号加一。

