#!/usr/bin/env python3
"""Audit script — findet '.htaccess'-getaggte 1P-Items, die der Agent nicht nutzen kann.

Prototyp für das geplante Defekt-Report-Feature. Spiegelt die Extraction-Logik aus
mac/Shared/ItemStore.swift::extractCredentials wider.

Usage:
    ./pf-audit.py
    ./pf-audit.py --account team.1password.com --tag .htaccess
"""
import argparse
import json
import os
import re
import subprocess
import sys
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor

CONFIG_PATH = "~/Library/Application Support/passwordfiller/config.json"
SECTION_REGEX = re.compile(r"(htaccess|basicauth|basic.?auth|htpasswd|webuser)", re.IGNORECASE)


def load_defaults() -> tuple[str, str]:
    path = os.path.expanduser(CONFIG_PATH)
    try:
        with open(path) as f:
            cfg = json.load(f)
        return cfg.get("op_account", ""), cfg.get("op_tag", ".htaccess")
    except FileNotFoundError:
        return "", ".htaccess"


def op_run(args: list[str], account: str) -> object:
    cmd = ["op"] + args + ["--account", account, "--format", "json"]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        sys.exit(f"❌ op {' '.join(args)} failed: {result.stderr.strip()}")
    return json.loads(result.stdout)


def list_tagged_items(tag: str, account: str) -> list[dict]:
    out = op_run(["item", "list", "--tags", tag], account)
    if not isinstance(out, list):
        sys.exit("❌ op item list returned unexpected shape")
    return [x for x in out if isinstance(x, dict)]


def get_item(item_id: str, account: str) -> dict:
    out = op_run(["item", "get", item_id], account)
    if not isinstance(out, dict):
        sys.exit(f"❌ op item get {item_id} returned unexpected shape")
    return out


def section_label(field: dict) -> str:
    section = field.get("section") or {}
    return section.get("label", "") or ""


def diagnose_credentials(item: dict) -> list[str]:
    """Mirrors ItemStore.extractCredentials in Swift.

    Section path: first STRING field is username, first CONCEALED is password.
    Field labels in the section are IRRELEVANT — only field type matters.
    Falls back to top-level if section is missing or incomplete.
    """
    fields = item.get("fields", []) or []

    # Section path
    section_fields = [f for f in fields if SECTION_REGEX.search(section_label(f))]
    section_user = next((f for f in section_fields if f.get("type") == "STRING"), None)
    section_pass = next((f for f in section_fields if f.get("type") == "CONCEALED"), None)
    s_user_ok = section_user is not None and bool(section_user.get("value"))
    s_pass_ok = section_pass is not None and bool(section_pass.get("value"))
    if s_user_ok and s_pass_ok:
        return []

    # Top-level fallback (matches by FIELD ID, not label)
    top_user = next((f for f in fields if f.get("id") == "username" and not f.get("section")), None)
    top_pass = next((f for f in fields if f.get("id") == "password" and not f.get("section")), None)
    t_user_ok = top_user is not None and bool(top_user.get("value"))
    t_pass_ok = top_pass is not None and bool(top_pass.get("value"))
    if t_user_ok and t_pass_ok:
        return []

    defects: list[str] = []
    if not (s_user_ok or t_user_ok):
        defects.append("Kein Username")
    if not (s_pass_ok or t_pass_ok):
        defects.append("Kein Password")
    return defects


def get_hostnames(item: dict) -> list[str]:
    out: list[str] = []
    for u in item.get("urls", []) or []:
        href = u.get("href", "") or ""
        s = href
        if "://" in s:
            s = s.split("://", 1)[1]
        s = s.split("/", 1)[0].split(":", 1)[0].lower().lstrip("*.")
        if s:
            out.append(s)
    return out


def audit(account: str, tag: str) -> int:
    print(f"🔍 Audit gegen {account} mit Tag '{tag}' …\n")
    summaries = list_tagged_items(tag, account)
    print(f"   {len(summaries)} Items mit Tag gefunden — lade Details (5 parallel) …\n")

    with ThreadPoolExecutor(max_workers=5) as pool:
        items = list(pool.map(lambda s: get_item(s["id"], account), summaries))

    findings: dict[tuple[str, str], list[str]] = defaultdict(list)
    hostname_to_items: dict[str, set[tuple[str, str]]] = defaultdict(set)

    for item in items:
        title = item.get("title", "(unbenannt)")
        vault = (item.get("vault") or {}).get("name", "?")
        key = (title, vault)

        hosts = get_hostnames(item)
        if not hosts:
            findings[key].append("Kein Website-Feld")
        else:
            for h in hosts:
                hostname_to_items[h].add(key)

        for d in diagnose_credentials(item):
            findings[key].append(d)

    # Ambiguity: exact-hostname collisions (mirrors the Agent's first match stage)
    for host, owners in hostname_to_items.items():
        if len(owners) <= 1:
            continue
        for owner in owners:
            others = sorted(f"'{t}' ({v})" for (t, v) in owners if (t, v) != owner)
            findings[owner].append(f"Hostname '{host}' kollidiert mit {', '.join(others)}")

    if not findings:
        print("✅ Keine Defekte gefunden.")
        return 0

    sorted_findings = sorted(findings.items(), key=lambda kv: kv[0][0].lower())
    print(f"⚠️  {len(sorted_findings)} Item(s) mit Defekten:\n")
    for (title, vault), defects in sorted_findings:
        print(f"  🔴 {title}  ·  {vault}")
        for d in defects:
            print(f"     • {d}")
        print()
    return 1


def main() -> None:
    default_account, default_tag = load_defaults()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--account", default=default_account)
    parser.add_argument("--tag", default=default_tag)
    args = parser.parse_args()

    if not args.account:
        sys.exit("❌ Kein op_account in config.json — bitte --account angeben")
    sys.exit(audit(args.account, args.tag))


if __name__ == "__main__":
    main()
