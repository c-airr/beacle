# Beacle

Local-first panel do zarządzania VPS. **Każdy user ma własny backend** — bundlowany z aplikacją, bez centralnego SaaS.

## Jak to działa

| Co | Gdzie |
|----|--------|
| Panel + backend | Twój PC — `beacle.exe` startuje lokalny backend automatycznie |
| Agenty | Linux VPS — `curl …/install \| bash` |
| Dane | Izolowane per user (`data/state.json` obok backendu) |

```
beacle.exe  →  uruchamia  →  beacle-backend.exe (localhost:8930)
                                      ↑
VPS agent ───── outbound ─────────────┘
```

## User z GitHub Releases

1. Pobierz zip: `beacle.exe` + `beacle-backend.exe` + folder `data/`
2. Uruchom `beacle.exe` — backend wstaje sam
3. **Settings → VPS** — skopiuj komendę install
4. Na każdym VPS: `curl … | sudo bash`
5. VPS pojawia się w Overview / Servers

**Agent URL** (adres w komendzie install) = Twój publiczny IP:8930 (auto) lub override w Settings jeśli masz port forward / tunnel.

## Build (maintainer)

```powershell
.\scripts\build.ps1
# Output: app\build\windows\x64\runner\Release\
```

## CGNAT

- Panel ↔ backend: zawsze localhost
- Agent → backend: **outbound** z VPS do Twojego publicznego URL
- Przy CGNAT u domu: ustaw override URL (np. tunel) w Settings → VPS, albo przekieruj port 8930 na routerze

## Monorepo

```
/app     Flutter + embedded backend launcher
/backend Go API (bundlowany jako beacle-backend.exe)
/agent   Linux agent (dystrybuowany przez lokalny backend)
/shared  DTO, PROTOCOL.md
```

Szczegóły: `STRUKTURA.txt`
