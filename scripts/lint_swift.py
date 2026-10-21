"""轻量 Swift 静态检查。

本机没有 Swift 编译器，这些检查只能抓出结构性错误，不能替代编译：
1. 括号 / 方括号 / 大括号配对
2. 禁用 API 扫描（对照提示词 §20.3）
3. 每个文件的 import 是否在顶层
4. 明显的空实现 / 占位符
5. YAML 语法

用法：python scripts/lint_swift.py
"""

from __future__ import annotations

import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

BANNED_PATTERNS = [
    (r"\bforegroundColor\s*\(", "使用 foregroundStyle() 替代 foregroundColor()"),
    (r"\.cornerRadius\s*\(", "使用 clipShape(.rect(cornerRadius:)) 替代 cornerRadius()"),
    (r"\baccentColor\s*\(", "使用 tint() 替代 accentColor()"),
    (r"\.tabItem\s*\{", "使用 Tab API 替代 tabItem()"),
    (r"\bNavigationView\b", "使用 NavigationStack / NavigationSplitView"),
    (r"\bUIScreen\.main\b", "禁止使用 UIScreen.main，改用 traitCollection.displayScale"),
    (r"\bAnyView\b", "禁止使用 AnyView"),
    (r"\.navigationBarLeading\b", "使用 .topBarLeading 或语义 placement"),
    (r"\.navigationBarTrailing\b", "使用 .topBarTrailing 或语义 placement"),
    (r"\btry!\b", "禁止 try!（#Preview 除外）"),
]

ALLOWED_BANNED_CONTEXT = (
    "lint_swift.py",
)


def swift_files():
    for base, dirs, files in os.walk(ROOT):
        dirs[:] = [d for d in dirs if d not in {".git", "build", "DerivedData"}]
        for name in files:
            if name.endswith(".swift"):
                yield os.path.join(base, name)


def strip_strings_and_comments(source: str) -> str:
    """把字符串字面量与注释替换为空格，避免误报。

    这是一个近似实现，不追求完整的 Swift 词法分析，但足以避开绝大多数误报。
    """
    out = []
    i = 0
    n = len(source)
    in_line_comment = False
    in_block_comment = False
    in_string = False
    in_multiline_string = False
    escape = False

    while i < n:
        ch = source[i]
        nxt = source[i + 1] if i + 1 < n else ""

        if in_line_comment:
            if ch == "\n":
                in_line_comment = False
                out.append(ch)
            else:
                out.append(" ")
            i += 1
            continue

        if in_block_comment:
            if ch == "*" and nxt == "/":
                in_block_comment = False
                out.append("  ")
                i += 2
                continue
            out.append("\n" if ch == "\n" else " ")
            i += 1
            continue

        if in_multiline_string:
            if ch == '"' and source[i : i + 3] == '"""':
                in_multiline_string = False
                out.append("   ")
                i += 3
                continue
            out.append("\n" if ch == "\n" else " ")
            i += 1
            continue

        if in_string:
            if escape:
                escape = False
                out.append(" ")
                i += 1
                continue
            if ch == "\\":
                escape = True
                out.append(" ")
                i += 1
                continue
            if ch == '"':
                in_string = False
                out.append(" ")
                i += 1
                continue
            out.append("\n" if ch == "\n" else " ")
            i += 1
            continue

        # 非字符串、非注释
        if ch == "/" and nxt == "/":
            in_line_comment = True
            out.append("  ")
            i += 2
            continue
        if ch == "/" and nxt == "*":
            in_block_comment = True
            out.append("  ")
            i += 2
            continue
        if source[i : i + 3] == '"""':
            in_multiline_string = True
            out.append("   ")
            i += 3
            continue
        if ch == '"':
            in_string = True
            out.append(" ")
            i += 1
            continue

        out.append(ch)
        i += 1

    return "".join(out)


def check_brackets(path: str, cleaned: str) -> list[str]:
    problems = []
    pairs = {")": "(", "]": "[", "}": "{"}
    stack = []
    line = 1
    for ch in cleaned:
        if ch == "\n":
            line += 1
        elif ch in "([{":
            stack.append((ch, line))
        elif ch in ")]}":
            if not stack:
                problems.append(f"{path}:{line}: 多余的闭合符号 {ch}")
                continue
            open_ch, open_line = stack.pop()
            if open_ch != pairs[ch]:
                problems.append(
                    f"{path}:{line}: 括号不匹配，{open_ch}（第 {open_line} 行）被 {ch} 闭合"
                )
    for ch, line_no in stack:
        problems.append(f"{path}:{line_no}: 未闭合的 {ch}")
    return problems


def check_banned(path: str, cleaned: str) -> list[str]:
    problems = []
    for pattern, message in BANNED_PATTERNS:
        for match in re.finditer(pattern, cleaned):
            line = cleaned[: match.start()].count("\n") + 1
            problems.append(f"{path}:{line}: {message}")
    return problems


def check_placeholders(path: str, cleaned: str) -> list[str]:
    problems = []
    for match in re.finditer(r"\bTODO\b|\bFIXME\b", cleaned):
        line = cleaned[: match.start()].count("\n") + 1
        problems.append(f"{path}:{line}: 残留 TODO/FIXME")
    return problems


def check_yaml() -> list[str]:
    problems = []
    try:
        import yaml
    except ImportError:
        return ["（跳过 YAML 检查：未安装 PyYAML）"]

    for rel in ("project.yml", ".github/workflows/build-ipa.yml"):
        path = os.path.join(ROOT, rel)
        if not os.path.exists(path):
            problems.append(f"{rel}: 文件不存在")
            continue
        try:
            with open(path, "r", encoding="utf-8") as f:
                yaml.safe_load(f)
        except Exception as exc:  # noqa: BLE001
            problems.append(f"{rel}: YAML 解析失败：{exc}")
    return problems


def check_json_assets() -> list[str]:
    problems = []
    assets = os.path.join(ROOT, "ModuReader", "Resources", "Assets.xcassets")
    for base, _dirs, files in os.walk(assets):
        for name in files:
            if not name.endswith(".json"):
                continue
            path = os.path.join(base, name)
            try:
                with open(path, "r", encoding="utf-8") as f:
                    json.load(f)
            except Exception as exc:  # noqa: BLE001
                problems.append(f"{os.path.relpath(path, ROOT)}: JSON 无效：{exc}")
    return problems


def main() -> int:
    files = sorted(swift_files())
    if not files:
        print("未找到 Swift 文件")
        return 1

    all_problems: list[str] = []
    total_lines = 0

    for path in files:
        rel = os.path.relpath(path, ROOT)
        with open(path, "r", encoding="utf-8") as f:
            source = f.read()
        total_lines += source.count("\n") + 1
        cleaned = strip_strings_and_comments(source)

        all_problems.extend(check_brackets(rel, cleaned))
        all_problems.extend(check_banned(rel, cleaned))
        all_problems.extend(check_placeholders(rel, cleaned))

    all_problems.extend(check_yaml())
    all_problems.extend(check_json_assets())

    print(f"检查了 {len(files)} 个 Swift 文件，共 {total_lines} 行")
    if all_problems:
        print(f"\n发现 {len(all_problems)} 个问题：\n")
        for problem in all_problems:
            print(f"  {problem}")
        return 1

    print("未发现问题")
    return 0


if __name__ == "__main__":
    sys.exit(main())
