---
name: release
description: >-
  IronBowl 项目专属一键发版流程。当用户说「发版」「发布」「发布新版本」「自动发版」「提 PR 发版」，或要求提交全部改动并合入 main 触发自动构建发布时使用。
---

# IronBowl 一键发版流程

按以下步骤完成本项目的标准发版闭环：提交所有未提交改动到 `dev` → 推送 `dev` → 创建并合并 `dev -> main` PR（保留 `dev`）→ 跟踪 GitHub Actions 发布流水线 → 同步 `origin/main` 版本提交回 `dev`。

## 1. 分支与远端检查

1. 确认已启用本地分支保护钩子并拉取远端最新状态：
   ```bash
   git config core.hooksPath .githooks
   git fetch origin --tags
   ```
2. 检查当前分支 `git branch --show-current`：
   - 正常应在 `dev` 分支；
   - 若位于 `feat/*` 或 `fix/*` 分支，先切回 `dev` 并合并该分支；
   - 若误在 `main` 分支，严禁在 `main` 上直接开发或提交，先切回 `dev` 处理。
3. 若 `origin/main` 领先当前 `dev`（例如上次 CI 发版产生的 `chore(release):` 提交尚未同步回 `dev`），先同步：
   ```bash
   git merge origin/main --no-edit
   ```
   （若出现冲突则立即停止并向用户汇报。）

## 2. 提交所有未提交改动到 `dev`

1. 查看工作区状态：
   ```bash
   git status --short
   ```
2. 若存在未提交改动或新增文件（排除 `.gitignore` 忽略项及明显的临时垃圾文件）：
   - 核对功能或配置改动是否需要同步更新 `docs/` 对应文档；如有代码改动，先运行受影响包的 `swift test` 验证通过。
   - 暂存全部改动并按项目 `AGENTS.md` 约定式提交规范（`类型(范围): 中文描述`，如 `feat(app): ...`、`fix(...): ...`、`chore(...): ...`）提交到 `dev`：
     ```bash
     git add -A
     git commit -m "<类型(范围): 中文描述>"
     ```
3. 核对待发布提交与版本预览：
   ```bash
   git log origin/main..HEAD --oneline
   python3 scripts/release.py plan
   ```
   - 若 `origin/main..HEAD` 为空且工作区也无改动，停止并询问用户是否要通过 `gh workflow run release.yml` 手动触发无新提交发版。

## 3. 推送 `dev` 分支

```bash
git push origin dev
```

## 4. 自动创建并合并 `dev -> main` PR（保留 `dev`）

1. 检查是否已有打开的 `dev -> main` PR：
   ```bash
   gh pr list --base main --head dev --state open --json number,url
   ```
2. 若没有打开的 PR，根据 `git log origin/main..HEAD` 生成中文标题与变更说明并创建 PR：
   ```bash
   gh pr create --base main --head dev \
     --title "release: 合并 dev 至 main（<简明中文摘要>）" \
     --body "<中文变更清单与发版说明>"
   ```
3. 立即合并该 PR（**严禁加 `--delete-branch`**，必须保留 `dev` 分支）：
   ```bash
   gh pr merge <PR号> --merge
   ```

## 5. 跟踪 GitHub Actions 发版流水线

1. 合并后等待数秒让 GitHub Actions 创建 workflow run，查询最新 `main` 分支上的 [`release.yml`](../../.github/workflows/release.yml) 运行记录（核对 `headSha` 与刚合并的 `origin/main` 一致）：
   ```bash
   git fetch origin main
   gh run list --workflow release.yml --branch main --limit 3 --json databaseId,status,conclusion,url,headSha,createdAt
   ```
2. 使用 `gh run watch <run-id> --exit-status` 等待流水线完成（设为后台长时间等待即可，不要手动轮询）。
3. 若流水线失败，执行 `gh run view <run-id> --log-failed` 定位错误并向用户汇报，不强行跳过。

## 6. 同步 `origin/main` 版本提交回 `dev` 并验收

1. 流水线成功后，将 CI 生成的 `chore(release): 发布 vX.Y.Z` 提交与 Tag 同步回 `dev`：
   ```bash
   git fetch origin --tags
   git checkout dev
   git merge origin/main --no-edit
   git push origin dev
   ```
2. 验证 GitHub Release 与上传产物完整（包含 `IronBowl` / `IronBowlCalendar` 的 `.dmg`、`.zip` 及其中文 `label` `饭碗-v...` / `万年历-v...`，以及 `SHA256SUMS.txt`、`appcast-ironbowl.xml`、`appcast-calendar.xml`）：
   ```bash
   gh release view <tag> --json tagName,url,assets
   ```
3. 向用户汇报最终版本号、PR 链接、GitHub Actions 链接与 Release 页面链接。
