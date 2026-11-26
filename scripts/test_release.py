#!/usr/bin/env python3
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import release


class ReleaseScriptTests(unittest.TestCase):
    def test_parse_conventional_commits(self) -> None:
        c1 = release.parse_commit("abc1234", "feat(calendar): 新增桌面小组件")
        self.assertEqual(c1.kind, "feat")
        self.assertEqual(c1.scope, "calendar")
        self.assertEqual(c1.description, "新增桌面小组件")
        self.assertFalse(c1.is_breaking)

        c2 = release.parse_commit("def5678", "fix!: 重置旧版数据库格式")
        self.assertEqual(c2.kind, "fix")
        self.assertIsNone(c2.scope)
        self.assertTrue(c2.is_breaking)

        c3 = release.parse_commit("1112223", "refactor(kit): 调整插件协议", "BREAKING CHANGE: 需要迁移")
        self.assertEqual(c3.kind, "refactor")
        self.assertTrue(c3.is_breaking)

        c4 = release.parse_commit("9990001", "杂项更新")
        self.assertEqual(c4.kind, "other")
        self.assertEqual(c4.description, "杂项更新")

    def test_compute_next_version_rules(self) -> None:
        fix = release.parse_commit("1", "fix: 修复崩溃")
        feat = release.parse_commit("2", "feat(ui): 新增版本展示")
        breaking = release.parse_commit("3", "feat!: 不兼容变更")

        self.assertEqual(release.compute_next_version("0.1.0", []), ("0.1.0", "none"))
        self.assertEqual(release.compute_next_version("0.1.0", [fix]), ("0.1.1", "patch"))
        self.assertEqual(release.compute_next_version("0.1.2", [fix, feat]), ("0.2.0", "minor"))
        self.assertEqual(release.compute_next_version("0.2.3", [breaking]), ("0.3.0", "minor"))
        self.assertEqual(release.compute_next_version("1.2.3", [breaking]), ("2.0.0", "major"))
        self.assertEqual(
            release.compute_next_version("0.1.0", [fix], override_version="v0.5.0"),
            ("0.5.0", "override"),
        )

    def test_render_release_notes_groups(self) -> None:
        commits = [
            release.parse_commit("aaa1111", "feat(app): 侧栏展示版本"),
            release.parse_commit("bbb2222", "fix(calendar): 修复闪烁"),
            release.parse_commit("ccc3333", "docs: 更新开发文档"),
            release.parse_commit("ddd4444", "ci(release): 新增发版流水线"),
            release.parse_commit("eee5555", "feat!: 调整配置结构"),
        ]
        notes = release.render_release_notes(
            version="0.2.0",
            build=2,
            commits=commits,
            prev_tag="v0.1.0",
            repo="taopaox/IronBowl",
        )
        self.assertIn("## IronBowl v0.2.0 (Build 2)", notes)
        self.assertIn("### ⚠️ 破坏性变更", notes)
        self.assertIn("### 新功能", notes)
        self.assertIn("### 修复", notes)
        self.assertIn("### 文档", notes)
        self.assertIn("### 构建与维护", notes)
        self.assertIn("IronBowl-v0.2.0-macOS-arm64.dmg", notes)
        self.assertIn("IronBowlCalendar-v0.2.0-macOS-arm64.zip", notes)
        self.assertIn("https://github.com/taopaox/IronBowl/compare/v0.1.0...v0.2.0", notes)

    def test_bump_project_yml(self) -> None:
        sample = (
            "name: IronBowl\n"
            "settings:\n"
            "  base:\n"
            '    MARKETING_VERSION: "0.1.0"\n'
            '    CURRENT_PROJECT_VERSION: "1"\n'
        )
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "project.yml"
            path.write_text(sample, encoding="utf-8")
            release.bump_project_yml(path, "0.2.0", 2)
            self.assertEqual(release.read_project_versions(path), ("0.2.0", 2))

    def test_parse_sign_update_output(self) -> None:
        raw = 'sparkle:edSignature="ZuOwgBjr627QB7VuVgMQ3r5NGFbsHjOR+p5nPTfxWSL2dS4emF02X+1YuhcPhcZH==" length="123456"\n'
        sig, length = release.parse_sign_update_output(raw)
        self.assertEqual(sig, "ZuOwgBjr627QB7VuVgMQ3r5NGFbsHjOR+p5nPTfxWSL2dS4emF02X+1YuhcPhcZH==")
        self.assertEqual(length, 123456)

        with self.assertRaises(ValueError):
            release.parse_sign_update_output("invalid output")

    def test_markdown_to_html_escapes_and_formats(self) -> None:
        md = (
            "## IronBowl v0.2.0 (Build 2)\n\n"
            "### 新功能\n"
            "- **app**: 支持 `Sparkle 2` <自动更新> ]]> 安全测试\n\n"
            "> 提示：**首次打开**请执行\n"
            "> ```bash\n"
            "> xattr -cr /Applications/IronBowl.app\n"
            "> ```\n"
        )
        rendered = release.markdown_to_html(md)
        self.assertIn("<h2>IronBowl v0.2.0 (Build 2)</h2>", rendered)
        self.assertIn("<h3>新功能</h3>", rendered)
        self.assertIn("<li><strong>app</strong>: 支持 <code>Sparkle 2</code> &lt;自动更新&gt;", rendered)
        self.assertIn("<pre><code>xattr -cr /Applications/IronBowl.app</code></pre>", rendered)
        self.assertNotIn("]]>", rendered)

    def test_render_appcast_xml_and_cli(self) -> None:
        notes = "## IronBowl v0.3.0 (Build 5)\n\n### 新功能\n- 接入 Sparkle 2 自动更新\n"
        xml_text = release.render_appcast_xml(
            app_name="饭碗 IronBowl",
            feed_url="https://github.com/taopaox/IronBowl/releases/latest/download/appcast-ironbowl.xml",
            release_url="https://github.com/taopaox/IronBowl/releases/tag/v0.3.0",
            download_url="https://github.com/taopaox/IronBowl/releases/download/v0.3.0/IronBowl-v0.3.0-macOS-arm64.zip",
            version="0.3.0",
            build=5,
            length=987654,
            ed_signature="abc123==",
            notes_markdown=notes,
            pub_date="Thu, 26 Nov 2026 10:00:00 GMT",
        )
        root = ET.fromstring(xml_text)
        ns = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
        item = root.find("./channel/item")
        self.assertIsNotNone(item)
        assert item is not None
        self.assertEqual(item.findtext("title"), "v0.3.0")
        self.assertEqual(item.findtext("sparkle:version", namespaces=ns), "5")
        self.assertEqual(item.findtext("sparkle:shortVersionString", namespaces=ns), "0.3.0")
        self.assertEqual(item.findtext("sparkle:minimumSystemVersion", namespaces=ns), "26.0")
        self.assertIn("接入 Sparkle 2 自动更新", item.findtext("description") or "")
        enclosure = item.find("enclosure")
        self.assertIsNotNone(enclosure)
        assert enclosure is not None
        self.assertEqual(enclosure.attrib["length"], "987654")
        self.assertEqual(
            enclosure.attrib["{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature"],
            "abc123==",
        )

        with tempfile.TemporaryDirectory() as tmp:
            tmp_dir = Path(tmp)
            archive = tmp_dir / "IronBowl.zip"
            archive.write_bytes(b"zip-bytes-content")
            notes_file = tmp_dir / "notes.md"
            notes_file.write_text(notes, encoding="utf-8")
            out_file = tmp_dir / "appcast-ironbowl.xml"
            rc = release.main(
                [
                    "appcast",
                    "--app-name",
                    "饭碗 IronBowl",
                    "--feed-url",
                    "https://github.com/taopaox/IronBowl/releases/latest/download/appcast-ironbowl.xml",
                    "--release-url",
                    "https://github.com/taopaox/IronBowl/releases/tag/v0.3.0",
                    "--download-url",
                    "https://github.com/taopaox/IronBowl/releases/download/v0.3.0/IronBowl.zip",
                    "--version",
                    "0.3.0",
                    "--build",
                    "5",
                    "--archive",
                    str(archive),
                    "--sign-output",
                    f'sparkle:edSignature="sigXYZ==" length="{archive.stat().st_size}"',
                    "--notes-file",
                    str(notes_file),
                    "--output",
                    str(out_file),
                ]
            )
            self.assertEqual(rc, 0)
            parsed = ET.parse(out_file).getroot()
            self.assertEqual(parsed.find("./channel/item/enclosure").attrib["length"], str(archive.stat().st_size))


if __name__ == "__main__":
    unittest.main()
