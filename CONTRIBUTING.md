# Contributing

xless is developed on GitHub, in [fmsouza/linux-apple-toolchain](https://github.com/fmsouza/linux-apple-toolchain),
through pull requests. Releases are made from `main` automatically.

## Branches and pull requests

- Work on a branch of your own, cut from an up-to-date `main`, and open a pull request against `main`.
- `main` is protected: every change arrives through a pull request, the required checks must pass, and force pushes
  are blocked.
- Pull requests are merged by **squash only**. The squash commit takes the pull request's title as its subject and its
  description as its body, so the **title** is what ends up in the history, the release notes and the version.
- Never add Apple files to the repository: no SDK, header, `.tbd`, binary or `.xip` content
  ([apple-requirements.md](docs/apple-requirements.md)).

## Titles: Conventional Commits

Every pull request title (and every commit subject) is a [Conventional Commit](https://www.conventionalcommits.org/),
at most 100 characters. The check is `scripts/check-commit-title.sh`, with this regular expression:

```
^(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)(\([a-z0-9._/-]+\))?!?: [^[:space:]].*$
```

- **type:** `feat` (a new feature), `fix` (a bug fix), `perf`, `docs`, `style`, `refactor`, `test`, `build`, `ci`,
  `chore` or `revert`;
- **scope** (optional): lower case, in parentheses, for example `fix(install): verify checksums`;
- **`!`** before the colon marks a breaking change, as does a `BREAKING CHANGE:` footer in the body.

Check a title locally with `scripts/check-commit-title.sh "feat(setup): accept an Xcode.app"`.

## Checks on every pull request

`.github/workflows/pr.yml` runs these; all six are required:

| Check | What it runs |
|---|---|
| `title` | The pull request title against the regular expression above |
| `linux-tests (x86_64)`, `linux-tests (arm64)` | `swift test`, AssetKit's tests and every `Tests/shell/*.test.sh`, in `swift:6.4.0-jammy` |
| `package (x86_64)`, `package (arm64)` | The release tarball built as a release would build it, installed with `scripts/install.sh` from a local release, and run |
| `shellcheck` | shellcheck on the shipped scripts |

CI never touches an Xcode, an SDK or an image, and uses no Apple secret.

Before you push, run what you can locally: `swift test`, `make test-linux` (the tests in Linux, through Docker),
`bash Tests/shell/<name>.test.sh`, and `python3 -I scripts/check-doc-links.py README.md CONTRIBUTING.md docs/*.md`
after editing the documentation.

## Versions and releases

A release workflow runs every night at 03:00 UTC. It looks at the titles of the commits on `main` since the last
release tag and computes the next version (`scripts/next-version.sh`):

| Commits since the last release | Next version |
|---|---|
| a breaking change (`!` or `BREAKING CHANGE:`) | the next major (`1.4.2` → `2.0.0`); while the major is 0, the next minor (`0.3.1` → `0.4.0`) |
| a `feat` | the next minor (`0.3.1` → `0.4.0`) |
| a `fix` or `perf` | the next patch (`0.3.1` → `0.3.2`) |
| only `docs`, `style`, `refactor`, `test`, `build`, `ci`, `chore` or `revert` | no release that night |

The highest bump wins. The release is tagged `v<version>` and its notes are generated from the same titles. The first
release, `v0.1.0`, is cut by hand ([maintainers.md](docs/maintainers.md#releases)). The source tree's version is always
`0.0.0-dev`; only a release build stamps the real one.

## Documentation

The root README is for a newcomer: what xless is, how to install it and build a first app. Everything else goes under
`docs/` ([docs/README.md](docs/README.md) is the index). The maintainer's private notes (`docs/superpowers/`,
`docs/acceptance/`) are git-ignored and stay local; never commit them.

## Licence

By contributing you agree that your contribution is released under the [MIT licence](LICENSE).
