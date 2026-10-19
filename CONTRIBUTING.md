# Contributing

- **Languages:** Go (backend, agent), Dart (Flutter app), C++ (native parts of the app) and Lua (plugins). Plugins are Lua only, see `docs/plugins`.
- **Issues first:** open an issue before a bigger change, so we agree on it before you write it. For a bug, include your OS, the Beacle version and what you did before it broke.
- **Checks:** run `go vet ./... && go test -race ./...` in `shared`, `backend` and `agent`, and `flutter analyze && flutter test` in `app`. CI runs the same.
- **Pull requests:** one fix or feature per PR, branched from `main`. Add a line to `CHANGELOG.md` if users will notice the change.
- **Licence:** contributions are GPL-3.0, like the rest of Beacle (`LICENSE`).
