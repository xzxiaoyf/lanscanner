#!/usr/bin/env python3
"""把 Support/oui.txt 转成 Swift raw 多行字符串，编译进二进制。

用法：python3 Support/generate_oui_embedded.py
背景：完整 OUI 库原先只作为 .app 的外部资源分发。在其他机器上，若应用
包被拆散、只复制了可执行文件、或资源读取失败，厂商识别会退化为内置小表。
内嵌一份可保证任何运行方式下都有完整的 IEEE 前缀数据；外部 oui.txt 仍
优先加载，方便用户自行更新数据库。
"""
import pathlib

root = pathlib.Path(__file__).resolve().parent.parent
src = root / "Support" / "oui.txt"
dst = root / "Sources" / "LANScanner" / "OUIEmbedded.swift"

text = src.read_text(encoding="utf-8")
assert '"""#' not in text, "oui.txt 含有 Swift raw 字符串的结束标记"

content = (
    "// 自动生成，请勿手工编辑。\n"
    "// 数据来源：Support/oui.txt（nmap MAC 前缀库：IEEE OUI / MA-M / MA-S）\n"
    "// 重新生成：python3 Support/generate_oui_embedded.py\n"
    "// 作用：把完整 OUI 库编译进二进制，避免外部资源缺失导致厂商识别失效。\n"
    "import Foundation\n\n"
    "enum OUIEmbedded {\n"
    "    static let text = #\"\"\"\n"
    + text
    + "\n\"\"\"#\n"
    "}\n"
)

dst.write_text(content, encoding="utf-8")
lines = sum(1 for line in text.splitlines() if line and not line.startswith("#"))
print(f"已生成 {dst}  ({dst.stat().st_size} 字节, 约 {lines} 条有效前缀)")
