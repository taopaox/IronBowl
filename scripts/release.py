#!/usr/bin/env python3
"""IronBowl 版本计算、更新日志生成与 project.yml 版本递增工具。"""

from __future__ import annotations

import argparse
import email.utils
import html
import json
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable
from xml.sax.saxutils import escape as xml_escape, quoteattr as xml_quoteattr

SEMVER_RE = re.compile(r"^v?(\d+)\.(\d+)\.(\d+)$")
CONVENTIONAL_RE = re.compile(
    r"^(?P<type>[a-zA-Z]+)(?:\((?P<scope>[^)]+)\))?(?P<bang>!)?:\s*(?P<desc>.+)$"
)
BREAKING_BODY_RE = re.compile(r"(?m)^BREAKING[ -]CHANGE:\s*")
MARKETING_RE = re.compile(r'(^\s*MARKETING_VERSION:\s*)"([^"]+)"', re.MULTILINE)
BUILD_RE = re.compile(r'(^\s*CURRENT_PROJECT_VERSION:\s*)"([^"]+)"', re.MULTILINE)
SIGN_ED_RE = re.compile(r'sparkle:edSignature="([^"]+)"')
SIGN_LENGTH_RE = re.compile(r'length="(\d+)"')
INLINE_CODE_SPLIT_RE = re.compile(r"(`[^`]+`)")
BOLD_RE = re.compile(r"\*\*([^*]+)\*\*")

KNOWN_TYPES = {"feat", "fix", "perf", "refactor", "docs", "test", "build", "ci", "chore"}

SECTION_ORDER: list[tuple[str, str, set[str]]] = [
    ("breaking", "⚠️ 破坏性变更", set()),
    ("feat", "新功能", {"feat"}),
    ("fix", "修复", {"fix"}),
    ("perf", "性能", {"perf"}),
    ("refactor", "重构", {"refactor"}),
    ("docs", "文档", {"docs"}),
    ("test", "测试", {"test"}),
    ("maintenance", "构建与维护", {"build", "ci", "chore"}),
    ("other", "其他变更", {"other"}),
]


@dataclass(frozen=True)
class CommitInfo:
    sha: str
    subject: str
    body: str
    kind: str
    scope: str | None
    description: str
    is_breaking: bool


def parse_semver(raw: str) -> tuple[int, int, int]:
    match = SEMVER_RE.match(raw.strip())
    if not match:
        raise ValueError(f"无效的语义化版本号: {raw!r}")
    return int(match.group(1)), int(match.group(2)), int(match.group(3))


def format_semver(parts: tuple[int, int, int]) -> str:
    return f"{parts[0]}.{parts[1]}.{parts[2]}"


def parse_commit(sha: str, subject: str, body: str = "") -> CommitInfo:
    clean_subject = subject.strip()
    clean_body = body.strip()
    match = CONVENTIONAL_RE.match(clean_subject)
    has_breaking_body = bool(BREAKING_BODY_RE.search(clean_body))
    if not match:
        return CommitInfo(
            sha=sha.strip(),
            subject=clean_subject,
            body=clean_body,
            kind="other",
            scope=None,
            description=clean_subject,
            is_breaking=has_breaking_body,
        )
    raw_type = match.group("type").lower()
    kind = raw_type if raw_type in KNOWN_TYPES else "other"
    scope = match.group("scope").strip() if match.group("scope") else None
    desc = match.group("desc").strip()
    is_breaking = bool(match.group("bang")) or has_breaking_body
    return CommitInfo(
        sha=sha.strip(),
        subject=clean_subject,
        body=clean_body,
        kind=kind,
        scope=scope,
        description=desc,
        is_breaking=is_breaking,
    )


def compute_next_version(
    base_version: str,
    commits: Iterable[CommitInfo],
    override_version: str | None = None,
) -> tuple[str, str]:
    commit_list = list(commits)
    if override_version:
        parsed = parse_semver(override_version)
        return format_semver(parsed), "override"
    if not commit_list:
        parsed = parse_semver(base_version)
        return format_semver(parsed), "none"

    major, minor, patch = parse_semver(base_version)
    if any(c.is_breaking for c in commit_list):
        # 对齐 AGENTS.md：0.x 阶段破坏性变更使次版本号加一；1.x+ 升主版本号
        if major == 0:
            return f"0.{minor + 1}.0", "minor"
        return f"{major + 1}.0.0", "major"
    if any(c.kind == "feat" for c in commit_list):
        return f"{major}.{minor + 1}.0", "minor"
    return f"{major}.{minor}.{patch + 1}", "patch"


def render_release_notes(
    version: str,
    build: int,
    commits: Iterable[CommitInfo],
    prev_tag: str | None = None,
    repo: str | None = None,
) -> str:
    commit_list = list(commits)
    lines: list[str] = [f"## IronBowl v{version} (Build {build})", ""]

    if not commit_list:
        lines.append("本次为手动触发版本发布，无新增提交记录。")
        lines.append("")
    else:
        for key, title, types in SECTION_ORDER:
            if key == "breaking":
                matched = [c for c in commit_list if c.is_breaking]
            else:
                matched = [c for c in commit_list if not c.is_breaking and c.kind in types]
            if not matched:
                continue
            lines.append(f"### {title}")
            for c in matched:
                prefix = f"**{c.scope}**: " if c.scope else ""
                lines.append(f"- {prefix}{c.description} ({c.sha})")
            lines.append("")

    lines.extend(
        [
            "### 安装包说明",
            f"- `IronBowl-v{version}-macOS-arm64.dmg` 与 `IronBowl-v{version}-macOS-arm64.zip`：饭碗主工作台（`IronBowl.app`，访达显示为「饭碗」）",
            f"- `IronBowlCalendar-v{version}-macOS-arm64.dmg` 与 `IronBowlCalendar-v{version}-macOS-arm64.zip`：独立版万年历（`IronBowlCalendar.app`，访达显示为「万年历」）",
            "- `SHA256SUMS.txt`：安装包 SHA-256 校验文件",
            "",
            "> **首次打开提示**：当前构建采用本地 Ad-Hoc 签名。若 macOS 提示无法验证开发者或文件已损坏，请将应用拖入 `/Applications` 后在终端执行：",
            "> ```bash",
            "> xattr -cr /Applications/IronBowl.app /Applications/IronBowlCalendar.app",
            "> ```",
        ]
    )

    if prev_tag and repo:
        lines.extend(["", f"**完整变更对比**：https://github.com/{repo}/compare/{prev_tag}...v{version}"])

    return "\n".join(lines).rstrip() + "\n"


def parse_sign_update_output(raw: str) -> tuple[str, int]:
    """解析 `sign_update` 标准输出中的 `sparkle:edSignature` 与 `length`。"""
    sig_match = SIGN_ED_RE.search(raw)
    len_match = SIGN_LENGTH_RE.search(raw)
    if not sig_match or not len_match:
        raise ValueError(f"无法从 sign_update 输出解析签名与字节长度: {raw!r}")
    signature = sig_match.group(1).strip()
    length = int(len_match.group(1))
    if not signature or length <= 0:
        raise ValueError(f"sign_update 输出包含无效签名或长度: {raw!r}")
    return signature, length


def _render_inline_markdown(text: str) -> str:
    parts = INLINE_CODE_SPLIT_RE.split(text)
    rendered: list[str] = []
    for part in parts:
        if len(part) >= 2 and part.startswith("`") and part.endswith("`"):
            rendered.append(f"<code>{html.escape(part[1:-1], quote=False)}</code>")
        else:
            escaped = html.escape(part, quote=False)
            rendered.append(BOLD_RE.sub(r"<strong>\1</strong>", escaped))
    return "".join(rendered)


def markdown_to_html(md: str) -> str:
    """将中文 Release Notes Markdown 安全渲染为简洁 HTML（用于 Appcast CDATA）。"""
    out: list[str] = []
    in_list = False
    in_quote = False
    in_code = False
    code_in_quote = False
    code_lines: list[str] = []

    def close_list() -> None:
        nonlocal in_list
        if in_list:
            out.append("</ul>")
            in_list = False

    def close_quote() -> None:
        nonlocal in_quote
        if in_quote:
            out.append("</blockquote>")
            in_quote = False

    for raw_line in md.splitlines():
        line = raw_line.rstrip()
        stripped = line.strip()

        if in_code:
            code_line = line
            if code_in_quote:
                q_stripped = code_line.lstrip()
                if q_stripped.startswith(">"):
                    code_line = q_stripped[1:].lstrip()
            if code_line.strip().startswith("```"):
                code_body = html.escape("\n".join(code_lines), quote=False)
                out.append(f"<pre><code>{code_body}</code></pre>")
                code_lines = []
                in_code = False
                code_in_quote = False
            else:
                code_lines.append(code_line)
            continue

        if stripped.startswith("```"):
            close_list()
            close_quote()
            in_code = True
            code_in_quote = False
            code_lines = []
            continue

        if not stripped:
            close_list()
            close_quote()
            continue

        if stripped.startswith(">"):
            close_list()
            quote_content = stripped[1:].lstrip()
            if quote_content.startswith("```"):
                close_quote()
                in_code = True
                code_in_quote = True
                code_lines = []
                continue
            if not in_quote:
                out.append("<blockquote>")
                in_quote = True
            out.append(f"<p>{_render_inline_markdown(quote_content)}</p>")
            continue

        close_quote()

        if stripped.startswith("### "):
            close_list()
            out.append(f"<h3>{_render_inline_markdown(stripped[4:].strip())}</h3>")
        elif stripped.startswith("## "):
            close_list()
            out.append(f"<h2>{_render_inline_markdown(stripped[3:].strip())}</h2>")
        elif stripped.startswith("- "):
            if not in_list:
                out.append("<ul>")
                in_list = True
            out.append(f"<li>{_render_inline_markdown(stripped[2:].strip())}</li>")
        else:
            close_list()
            out.append(f"<p>{_render_inline_markdown(stripped)}</p>")

    if in_code:
        code_body = html.escape("\n".join(code_lines), quote=False)
        out.append(f"<pre><code>{code_body}</code></pre>")
    close_list()
    close_quote()
    return "\n".join(out).replace("]]>", "]]&gt;")


def render_appcast_xml(
    *,
    app_name: str,
    feed_url: str,
    release_url: str,
    download_url: str,
    version: str,
    build: int,
    length: int,
    ed_signature: str,
    notes_markdown: str = "",
    minimum_system_version: str = "26.0",
    pub_date: str | None = None,
) -> str:
    """生成符合 Sparkle 2 规范的 RSS 2.0 Appcast XML。"""
    parse_semver(version)
    if build < 1:
        raise ValueError(f"build 号必须为正整数: {build}")
    if length <= 0:
        raise ValueError(f"安装包字节长度必须大于 0: {length}")
    clean_sig = ed_signature.strip()
    if not clean_sig:
        raise ValueError("ed_signature 不能为空")

    pub = pub_date or email.utils.formatdate(usegmt=True)
    notes_html = markdown_to_html(notes_markdown) if notes_markdown.strip() else f"<p>{xml_escape(app_name)} v{xml_escape(version)}</p>"
    notes_html = notes_html.replace("]]>", "]]&gt;")

    lines = [
        '<?xml version="1.0" encoding="utf-8"?>',
        '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">',
        "  <channel>",
        f"    <title>{xml_escape(app_name)} 更新日志</title>",
        f"    <link>{xml_escape(feed_url)}</link>",
        f"    <description>{xml_escape(app_name)} 自动更新发布源</description>",
        "    <language>zh-cn</language>",
        "    <item>",
        f"      <title>v{xml_escape(version)}</title>",
        f"      <link>{xml_escape(release_url)}</link>",
        f"      <pubDate>{xml_escape(pub)}</pubDate>",
        f"      <sparkle:version>{build}</sparkle:version>",
        f"      <sparkle:shortVersionString>{xml_escape(version)}</sparkle:shortVersionString>",
        f"      <sparkle:minimumSystemVersion>{xml_escape(minimum_system_version)}</sparkle:minimumSystemVersion>",
        f"      <description><![CDATA[{notes_html}]]></description>",
        (
            f"      <enclosure url={xml_quoteattr(download_url)} "
            f"length={xml_quoteattr(str(length))} "
            'type="application/octet-stream" '
            f"sparkle:edSignature={xml_quoteattr(clean_sig)} />"
        ),
        "    </item>",
        "  </channel>",
        "</rss>",
    ]
    return "\n".join(lines) + "\n"


def read_project_versions(project_yml: Path) -> tuple[str, int]:
    content = project_yml.read_text(encoding="utf-8")
    m_ver = MARKETING_RE.search(content)
    b_ver = BUILD_RE.search(content)
    if not m_ver or not b_ver:
        raise ValueError(f"无法在 {project_yml} 中解析 MARKETING_VERSION 或 CURRENT_PROJECT_VERSION")
    return m_ver.group(2), int(b_ver.group(2))


def bump_project_yml(project_yml: Path, version: str, build: int) -> None:
    parse_semver(version)
    if build < 1:
        raise ValueError(f"build 号必须为正整数: {build}")
    content = project_yml.read_text(encoding="utf-8")
    new_content, count_m = MARKETING_RE.subn(rf'\1"{version}"', content, count=1)
    new_content, count_b = BUILD_RE.subn(rf'\1"{build}"', new_content, count=1)
    if count_m != 1 or count_b != 1:
        raise ValueError(f"更新 {project_yml} 版本字段失败 (marketing={count_m}, build={count_b})")
    project_yml.write_text(new_content, encoding="utf-8")


def run_git(args: list[str], cwd: Path) -> str:
    proc = subprocess.run(
        ["git", *args],
        cwd=str(cwd),
        check=True,
        capture_output=True,
        text=True,
    )
    return proc.stdout


def latest_version_tag(cwd: Path) -> str | None:
    out = run_git(["tag", "--merged", "HEAD", "--list", "v*", "--sort=-v:refname"], cwd)
    for line in out.splitlines():
        tag = line.strip()
        if SEMVER_RE.match(tag):
            return tag
    return None


def collect_commits(cwd: Path, since_tag: str | None) -> list[CommitInfo]:
    rev_range = f"{since_tag}..HEAD" if since_tag else "HEAD"
    raw = run_git(["log", rev_range, "--no-merges", "--format=%h%x1f%s%x1f%b%x1e"], cwd)
    commits: list[CommitInfo] = []
    for record in raw.split("\x1e"):
        record = record.strip()
        if not record:
            continue
        parts = record.split("\x1f", 2)
        sha = parts[0] if len(parts) > 0 else ""
        subject = parts[1] if len(parts) > 1 else ""
        body = parts[2] if len(parts) > 2 else ""
        if subject.strip().startswith("chore(release):"):
            continue
        commits.append(parse_commit(sha, subject, body))
    if len(commits) > 1:
        commits = [c for c in commits if c.subject != "Initial commit"]
    return commits


def write_github_outputs(path: Path, data: dict[str, str]) -> None:
    with path.open("a", encoding="utf-8") as fh:
        for k, v in data.items():
            fh.write(f"{k}={v}\n")


def cmd_plan(args: argparse.Namespace) -> int:
    repo_root = Path(args.repo_root).resolve()
    project_yml = (repo_root / args.project_yml).resolve()
    marketing_ver, current_build = read_project_versions(project_yml)
    prev_tag = latest_version_tag(repo_root)
    base_version = prev_tag.lstrip("vV") if prev_tag else marketing_ver
    commits = collect_commits(repo_root, prev_tag)
    next_version, bump_kind = compute_next_version(
        base_version=base_version,
        commits=commits,
        override_version=args.override_version,
    )
    should_release = bool(args.override_version or commits)
    next_build = current_build + 1 if should_release else current_build
    notes = render_release_notes(
        version=next_version,
        build=next_build,
        commits=commits,
        prev_tag=prev_tag,
        repo=args.repo,
    )

    if args.notes_file:
        notes_path = Path(args.notes_file)
        notes_path.parent.mkdir(parents=True, exist_ok=True)
        notes_path.write_text(notes, encoding="utf-8")

    payload = {
        "should_release": "true" if should_release else "false",
        "prev_tag": prev_tag or "",
        "base_version": base_version,
        "version": next_version,
        "tag": f"v{next_version}",
        "build": str(next_build),
        "bump_kind": bump_kind,
        "commit_count": str(len(commits)),
    }
    if args.github_output:
        write_github_outputs(Path(args.github_output), payload)

    print(json.dumps({**payload, "notes": notes}, ensure_ascii=False, indent=2))
    return 0


def cmd_bump(args: argparse.Namespace) -> int:
    repo_root = Path(args.repo_root).resolve()
    project_yml = (repo_root / args.project_yml).resolve()
    bump_project_yml(project_yml, args.version, args.build)
    print(f"Updated {project_yml} -> MARKETING_VERSION={args.version}, CURRENT_PROJECT_VERSION={args.build}")
    return 0


def cmd_appcast(args: argparse.Namespace) -> int:
    if bool(args.sign_output) == bool(args.ed_signature):
        raise ValueError("必须且只能提供 --sign-output 或 --ed-signature 之一")

    archive_path = Path(args.archive).resolve() if args.archive else None
    if archive_path is not None and not archive_path.is_file():
        raise FileNotFoundError(f"找不到安装包文件: {archive_path}")

    if args.sign_output:
        ed_signature, length = parse_sign_update_output(args.sign_output)
        if archive_path is not None:
            actual_size = archive_path.stat().st_size
            if actual_size != length:
                raise ValueError(f"安装包字节数不匹配: file={actual_size}, sign_update={length}")
    else:
        ed_signature = args.ed_signature.strip()
        if args.length is not None:
            length = args.length
        elif archive_path is not None:
            length = archive_path.stat().st_size
        else:
            raise ValueError("使用 --ed-signature 时必须同时提供 --archive 或 --length")
        if archive_path is not None and archive_path.stat().st_size != length:
            raise ValueError(f"安装包字节数不匹配: file={archive_path.stat().st_size}, length={length}")

    notes_md = ""
    if args.notes_file:
        notes_md = Path(args.notes_file).read_text(encoding="utf-8")

    xml_text = render_appcast_xml(
        app_name=args.app_name,
        feed_url=args.feed_url,
        release_url=args.release_url,
        download_url=args.download_url,
        version=args.version,
        build=args.build,
        length=length,
        ed_signature=ed_signature,
        notes_markdown=notes_md,
        minimum_system_version=args.minimum_system_version,
    )
    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(xml_text, encoding="utf-8")
    print(f"Generated Sparkle appcast -> {output_path} (version={args.version}, build={args.build}, length={length})")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="IronBowl 自动版本规划与 project.yml 更新工具")
    parser.add_argument("--repo-root", default=".", help="Git 仓库根目录")
    parser.add_argument("--project-yml", default="project.yml", help="project.yml 相对路径")
    sub = parser.add_subparsers(dest="command", required=True)

    p_plan = sub.add_parser("plan", help="计算下一个版本号并生成 Release Notes")
    p_plan.add_argument("--override-version", default=None, help="手动指定目标版本号（如 0.3.0）")
    p_plan.add_argument("--repo", default=None, help="GitHub 仓库名（如 owner/repo）")
    p_plan.add_argument("--notes-file", default=None, help="输出 Release Notes 到指定 Markdown 文件")
    p_plan.add_argument("--github-output", default=None, help="写入 GitHub Actions GITHUB_OUTPUT 文件")
    p_plan.set_defaults(func=cmd_plan)

    p_bump = sub.add_parser("bump", help="更新 project.yml 中的版本号和构建号")
    p_bump.add_argument("--version", required=True, help="目标版本号（如 0.2.0）")
    p_bump.add_argument("--build", required=True, type=int, help="目标构建号（如 2）")
    p_bump.set_defaults(func=cmd_bump)

    p_appcast = sub.add_parser("appcast", help="生成 Sparkle 2 Appcast XML")
    p_appcast.add_argument("--app-name", required=True, help="应用显示名称")
    p_appcast.add_argument("--feed-url", required=True, help="Appcast XML 公开地址")
    p_appcast.add_argument("--release-url", required=True, help="GitHub Release 页面地址")
    p_appcast.add_argument("--download-url", required=True, help="ZIP 安装包下载地址")
    p_appcast.add_argument("--version", required=True, help="语义化版本号（如 0.2.0）")
    p_appcast.add_argument("--build", required=True, type=int, help="构建号（如 2）")
    p_appcast.add_argument("--archive", default=None, help="本地 ZIP 安装包路径（用于核验字节长度）")
    p_appcast.add_argument("--sign-output", default=None, help="sign_update 命令的标准输出文本")
    p_appcast.add_argument("--ed-signature", default=None, help="直接传入 Ed25519 签名字符串")
    p_appcast.add_argument("--length", default=None, type=int, help="手动指定安装包字节长度")
    p_appcast.add_argument("--minimum-system-version", default="26.0", help="最低支持的 macOS 版本")
    p_appcast.add_argument("--notes-file", default=None, help="Release Notes Markdown 文件路径")
    p_appcast.add_argument("--output", required=True, help="输出的 appcast.xml 路径")
    p_appcast.set_defaults(func=cmd_appcast)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
