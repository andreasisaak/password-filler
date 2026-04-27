# Dev Scripts

Helfer für die lokale Agent-Entwicklung. Entstanden beim Phase-2-Review-Gate (2026-04-21) — siehe
[`specs/v1-mac-app/phase-2-spike-learnings.md`](../../../specs/v1-mac-app/phase-2-spike-learnings.md)
für den Kontext, warum jedes einzelne davon existiert.

**Wichtig:** Alle Scripts sind für die **Dev-Umgebung**. Production nutzt `SMAppService.agent(plistName:)`
aus der Main-App heraus (Phase 4). Die Scripts hier schmieren an SMAppService vorbei, damit wir den
Agent-Core vor der Main-App validieren können.

## Quick Start

```bash
# Einmalig: App-Bundle bauen + signieren + nach /Applications/
./pf-install.sh

# Danach für schnelle Dev-Iteration (Code ändern → rebuild → test):
./pf-full-cycle.sh
```

## Scripts im Detail

| Script | Zweck |
|---|---|
| `pf-socket.py` | Unix-Socket-Client für den Agent. Spricht das Length-prefixed-JSON-Protokoll (verbatim kompatibel zum Legacy-NMH-Host). Actions: `ping`, `config`, `list`, `refresh`, `lookup <host>`. |
| `pf-install.sh` | Baut `PasswordFiller.app` mit embedded Agent + `pf-nmh-bridge` + Appexes. Signiert alles mit Developer ID + Hardened Runtime. Installiert nach `/Applications/`. |
| `pf-la-install.sh` | Workaround-LaunchAgent-Install: Schreibt eine dev-taugliche Plist mit **absolutem** `Program`-Pfad (statt `BundleProgram`, das nur über `SMAppService` aufgelöst wird) nach `~/Library/LaunchAgents/` und registriert sie via `launchctl bootstrap`. Triggert den Agent einmal via `kickstart`. |
| `pf-full-cycle.sh` | Rebuild Agent → in `/Applications/` kopieren + neu signieren → LaunchAgent reloaden → Refresh-Test. Der übliche Code→Test-Loop in einem Befehl. |
| `pf-restart.sh` | Nur den Agent neu starten (ohne Rebuild). |
| `pf-smoke.sh` | Minimal-Test: Agent spawnen, Ping, Tot. Nützlich zum schnellen Gesundheitscheck. |
| `pf-diag.sh` | Diagnostik: os_log letzte 3 min, Agent-stderr, laufende `op`-Subprocesses, Agent-Prozess-State. |

## Warum brauchen wir diesen Workaround überhaupt?

Phase 2 testet den Agent (Unix-Socket, XPC, `op`-CLI-Bridge). Phase 4 liefert die Main-App mit
`SMAppService.agent(plistName:)`. Wir können Phase 2 aber nur testen wenn der Agent:

1. **Signiert** ist (sonst verweigert 1Password Desktop-App-Auth)
2. **Aus `/Applications/`** läuft (sonst findet `SMAppService.agent` den Plist nicht)
3. **Von `launchd` gestartet** wird (sonst kein vertrauenswürdiger Parent-Process für `op`)

Die Scripts lösen diese 3 Anforderungen in minimalem Phase-4-Vorgriff: `PasswordFillerApp.swift`
ist ein nackter `@main`-Stub mit `SMAppService.agent.register()`-Call; `pf-la-install.sh` registriert
parallel eine klassische LaunchAgent-Plist als Fallback (falls SMAppService den Plist nicht akzeptiert,
was bei Force-Re-Sign-Metadaten-Inkonsistenzen vorkommen kann).

Sobald Phase 4 die echte Main-App liefert, verschwindet der `pf-la-install.sh`-Workaround wieder —
SMAppService ist dann der einzige korrekte Pfad.

## Cleanup

```bash
# LaunchAgent entfernen:
launchctl bootout "gui/$(id -u)/app.passwordfiller.agent"
rm ~/Library/LaunchAgents/app.passwordfiller.agent.plist

# App deinstallieren:
rm -rf /Applications/PasswordFiller.app

# Socket + Support-Dir:
rm -rf ~/Library/Application\ Support/app.passwordfiller/
rm -rf ~/Library/Application\ Support/passwordfiller/  # nur wenn config.json auch weg soll
```
