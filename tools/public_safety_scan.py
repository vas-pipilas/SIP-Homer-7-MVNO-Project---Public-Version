#!/usr/bin/env python3
"""Fail CI when public portfolio content looks unsafe to publish.

The rules are intentionally generic. Do not put real private/customer identifiers
into this scanner as deny-list entries: doing so would publish the identifiers.
"""

from __future__ import annotations

import ipaddress
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TEXT_SUFFIXES = {".md", ".txt", ".sh", ".py", ".sql", ".yml", ".yaml", ".json"}
SKIP_DIRS = {".git", ".venv", "venv", "__pycache__"}

EMAIL_RE = re.compile(r"(?i)\b[A-Z0-9._%+-]+@([A-Z0-9.-]+\.[A-Z]{2,})\b")
IPV4_RE = re.compile(r"(?<![0-9.])(?:\d{1,3}\.){3}\d{1,3}(?![0-9.])")
SECRET_ASSIGNMENT_RE = re.compile(
    r"(?i)\b(password|passwd|token|secret|api[_-]?key|private[_-]?key)\b\s*[:=]\s*['\"]?[^\s'\"${}<]{6,}"
)
PRIVATE_KEY_RE = re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----")

ALLOWED_EMAIL_DOMAINS = {"example.com", "example.net", "example.org"}
ALLOWED_NETWORKS = [
    ipaddress.ip_network("127.0.0.0/8"),
    ipaddress.ip_network("192.0.2.0/24"),       # TEST-NET-1
    ipaddress.ip_network("198.51.100.0/24"),    # TEST-NET-2
    ipaddress.ip_network("203.0.113.0/24"),     # TEST-NET-3
]


def iter_text_files():
    for path in ROOT.rglob("*"):
        if not path.is_file():
            continue
        if any(part in SKIP_DIRS for part in path.parts):
            continue
        if path.suffix.lower() in TEXT_SUFFIXES or path.name in {"README", ".gitignore"}:
            yield path


def line_number(text: str, offset: int) -> int:
    return text.count("\n", 0, offset) + 1


def allowed_ip(value: str) -> bool:
    try:
        ip = ipaddress.ip_address(value)
    except ValueError:
        return False
    return any(ip in network for network in ALLOWED_NETWORKS)


def main() -> int:
    findings: list[str] = []

    for path in iter_text_files():
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        rel = path.relative_to(ROOT)

        for match in EMAIL_RE.finditer(text):
            domain = match.group(1).lower()
            if domain not in ALLOWED_EMAIL_DOMAINS:
                findings.append(
                    f"{rel}:{line_number(text, match.start())}: non-example email domain: {domain}"
                )

        for match in IPV4_RE.finditer(text):
            value = match.group(0)
            try:
                ipaddress.ip_address(value)
            except ValueError:
                continue
            if not allowed_ip(value):
                findings.append(
                    f"{rel}:{line_number(text, match.start())}: IPv4 address is not loopback/RFC5737 documentation space: {value}"
                )

        for match in PRIVATE_KEY_RE.finditer(text):
            findings.append(
                f"{rel}:{line_number(text, match.start())}: private-key material detected"
            )

        # Ignore documentation prose such as "password: hidden" by requiring a
        # concrete literal of at least six non-placeholder characters.
        for match in SECRET_ASSIGNMENT_RE.finditer(text):
            snippet = match.group(0)
            if any(marker in snippet for marker in ("${", "<", ">", "example")):
                continue
            findings.append(
                f"{rel}:{line_number(text, match.start())}: possible literal secret assignment"
            )

    if findings:
        print("PUBLICATION SAFETY SCAN: FAILED")
        for finding in findings:
            print(f" - {finding}")
        return 1

    print("PUBLICATION SAFETY SCAN: PASS")
    print("No non-example email domains, non-documentation IPv4 addresses, private keys or obvious literal secrets found.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
