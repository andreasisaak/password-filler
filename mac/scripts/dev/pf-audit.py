#!/usr/bin/env python3
"""Audit script — findet '.htaccess'-getaggte 1P-Items, die der Agent nicht nutzen kann.

Prototyp für das geplante Defekt-Report-Feature. Spiegelt die Extraction- und
Merge-Logik aus mac/Shared/ItemStore.swift wider:

- extractCredentials: Section-Pfad (STRING/CONCEALED) → Top-Level-Fallback (id-basiert)
- mergedForDisplay: Items mit identischem (title, hostnames-set, user, pass)
  werden zu EINEM logischen Eintrag gefaltet (entspricht "x Vaults"-Badge).

Daher werden Items, die nur "Kollision mit ihrem eigenen Merge-Twin" haben,
nicht als Defekt geflaggt — der Agent handhabt das transparent.

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


def analyze_credentials(item: dict) -> dict:
    """Mirrors ItemStore.extractCredentials AND diagnoses section integrity.

    Section path: first STRING field is username, first CONCEALED is password.
    Field labels in the section are IRRELEVANT — only field type matters.
    Falls back to top-level (id-based) if section is missing or incomplete.

    Returns dict with:
        user, pwd        -- resolved values (either path)
        section_present  -- a section matching SECTION_REGEX exists (any field in it)
        section_user_ok  -- section has STRING field with non-empty value
        section_pass_ok  -- section has CONCEALED field with non-empty value
    """
    fields = item.get("fields", []) or []

    section_fields = [f for f in fields if SECTION_REGEX.search(section_label(f))]
    section_user = next((f for f in section_fields if f.get("type") == "STRING"), None)
    section_pass = next((f for f in section_fields if f.get("type") == "CONCEALED"), None)
    s_user = (section_user.get("value") if section_user else None) or None
    s_pass = (section_pass.get("value") if section_pass else None) or None

    top_user_field = next(
        (f for f in fields if f.get("id") == "username" and not f.get("section")), None
    )
    top_pass_field = next(
        (f for f in fields if f.get("id") == "password" and not f.get("section")), None
    )
    t_user = (top_user_field.get("value") if top_user_field else None) or None
    t_pass = (top_pass_field.get("value") if top_pass_field else None) or None

    if s_user and s_pass:
        user, pwd = s_user, s_pass
    elif t_user and t_pass:
        user, pwd = t_user, t_pass
    else:
        user, pwd = (s_user or t_user), (s_pass or t_pass)

    return {
        "user": user,
        "pwd": pwd,
        "section_present": bool(section_fields),
        "section_user_ok": bool(s_user),
        "section_pass_ok": bool(s_pass),
    }


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
        raw_items = list(pool.map(lambda s: get_item(s["id"], account), summaries))

    # Reduce to minimal in-memory shape (creds held for merge identity, never printed)
    items_data: list[dict] = []
    for raw in raw_items:
        analysis = analyze_credentials(raw)
        items_data.append({
            "title": raw.get("title", "(unbenannt)"),
            "vault": (raw.get("vault") or {}).get("name", "?"),
            "hostnames": get_hostnames(raw),
            "user": analysis["user"],
            "pwd": analysis["pwd"],
            "section_present": analysis["section_present"],
            "section_user_ok": analysis["section_user_ok"],
            "section_pass_ok": analysis["section_pass_ok"],
        })

    # Merge twins: identical (title, hostnames-set, user, pass) collapse to ONE logical item.
    # Mirrors ItemStore.mergedForDisplay — these never collide in the Agent's lookup.
    merge_key = lambda d: (d["title"], tuple(sorted(d["hostnames"])), d["user"] or "", d["pwd"] or "")
    merge_groups: dict[tuple, list[dict]] = defaultdict(list)
    for item in items_data:
        merge_groups[merge_key(item)].append(item)

    # Map hostname -> set of distinct merge-group keys
    hostname_to_groups: dict[str, set[tuple]] = defaultdict(set)
    for key, members in merge_groups.items():
        for h in members[0]["hostnames"]:
            hostname_to_groups[h].add(key)

    findings: dict[tuple[str, str], list[str]] = {}
    for key, members in merge_groups.items():
        canonical = members[0]
        title = canonical["title"]
        vaults = sorted({m["vault"] for m in members})
        vault_label = vaults[0] if len(vaults) == 1 else f"{vaults[0]} (+{len(vaults) - 1} weitere)"

        defects: list[str] = []

        if not canonical["hostnames"]:
            defects.append("Kein Website-Feld")

        # Section-broken-but-fallback-works: User signalisiert "Creds gehören in Section",
        # aber Section-Felder sind unvollständig. Agent fällt heimlich auf Top-Level zurück
        # — das sind aber typischerweise andere Credentials (z.B. CMS-Login statt Basic-Auth).
        if canonical["section_present"] and not (canonical["section_user_ok"] and canonical["section_pass_ok"]):
            if not canonical["section_user_ok"]:
                defects.append(
                    "Section vorhanden, Username-Feld fehlt oder leer "
                    "— Agent fällt auf Top-Level zurück (vermutlich falsche Credentials)"
                )
            if not canonical["section_pass_ok"]:
                defects.append(
                    "Section vorhanden, Password-Feld nicht vom Typ Password "
                    "(z.B. als Text-Feld) — Agent fällt auf Top-Level zurück "
                    "(vermutlich falsche Credentials)"
                )
        else:
            # Keine Section vorhanden ODER Section komplett — dann sollte mind. eine Quelle Creds liefern
            if not canonical["user"]:
                defects.append("Kein Username")
            if not canonical["pwd"]:
                defects.append("Kein Password")

        # Collisions: bundle per OTHER merge group instead of per hostname.
        # Same-title + identical hostname-set = vault-duplikat with divergent creds
        # (often a forgotten password rotation in one vault). Otherwise: real cross-conflict.
        canonical_hostnames_set = set(canonical["hostnames"])
        collisions_by_other: dict[tuple, list[str]] = defaultdict(list)
        for h in canonical["hostnames"]:
            for other_key in hostname_to_groups[h] - {key}:
                collisions_by_other[other_key].append(h)

        for other_key, shared in collisions_by_other.items():
            other_members = merge_groups[other_key]
            other_canonical = other_members[0]
            other_title = other_canonical["title"]
            other_vaults = " / ".join(sorted({m["vault"] for m in other_members}))
            other_hostnames_set = set(other_canonical["hostnames"])

            is_vault_duplicate = (
                other_title == canonical["title"]
                and other_hostnames_set == canonical_hostnames_set
            )

            if is_vault_duplicate:
                defects.append(
                    f"Vermutliches Vault-Duplikat mit '{other_title}' ({other_vaults}) "
                    f"— gleiche {len(shared)} Hostnames, aber abweichende Credentials"
                )
            elif len(shared) == 1:
                defects.append(
                    f"Hostname-Konflikt mit '{other_title}' ({other_vaults}) "
                    f"auf '{shared[0]}'"
                )
            else:
                shared_preview = ", ".join(sorted(shared)[:3])
                more = f" (+{len(shared) - 3} weitere)" if len(shared) > 3 else ""
                defects.append(
                    f"Konflikt mit '{other_title}' ({other_vaults}) "
                    f"auf {len(shared)} Hostnames: {shared_preview}{more}"
                )

        if defects:
            findings[(title, vault_label)] = defects

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
