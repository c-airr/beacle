# Contributing to Beacle

Thanks for wanting to help. Bug reports, ideas, plugins and pull requests are all welcome.

## Before you start

- **Bugs and ideas** — open an issue first. For a bug, include your OS, the Beacle version and what you did right before it broke.
- **Bigger changes** — say what you plan to do in an issue before writing it, so nobody builds something that won't be merged.
- **Plugins** — you don't need to touch this repo. See [docs/plugins](docs/plugins/README.md); examples live in `plugins/demo`.

## Repository layout

| Folder | What it is |
|---|---|
| `app/` | Flutter desktop app (Windows, Linux, macOS) |
| `backend/` | Go server that runs next to the app (REST + WebSocket, alerts) |
| `agent/` | Go agent installed on each Linux VPS |
| `shared/` | Go types shared by backend and agent — the source of truth for the API (`shared/PROTOCOL.md`) |
| `plugins/`, `docs/plugins/` | Plugin editor files, demo plugins and the plugin API docs |

`backend`, `agent` and `shared` form one Go workspace (`go.work`).

## Building and testing

You need Go (version from `agent/go.mod`) and Flutter (version pinned in `.github/workflows/build-check.yml`).

```bash
# Go: backend, agent, shared
for m in shared backend agent; do (cd "$m" && go vet ./... && go test -race ./...); done

# Flutter app
cd app && flutter pub get && flutter analyze --no-fatal-infos && flutter test
```

These are exactly the checks the **Build check** workflow runs on every pull request, so if they pass locally CI should too. To build everything, use `scripts/build.sh` (Linux/macOS) or `scripts/build.ps1` (Windows); `scripts/start-dev.ps1` starts a dev setup.

## Pull requests

1. Fork the repo and branch from `main`.
2. Keep the PR focused — one fix or feature per PR.
3. Match the style of the surrounding code; run `gofmt` on Go and `dart format` on Dart.
4. Add or update tests when you change behaviour.
5. If you change what users see, add a line under the newest heading in [CHANGELOG.md](CHANGELOG.md).
6. If you change the API between app, backend and agent, update `shared/` and `shared/PROTOCOL.md` together.
7. Make sure CI is green.

## Releases

Maintainers only. Releases are built and attested by the **Release** workflow from a tag — never upload binaries by hand. See "Cut a release" in the [README](README.md).

## License

Beacle is licensed under the [GNU GPL v3.0](LICENSE). By submitting a contribution you agree that it is licensed under the same terms.
