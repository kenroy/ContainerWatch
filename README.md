# ContainerWatch

A macOS menu bar app that watches the containers running under Apple's [`container`](https://github.com/apple/container) tool and tells you when newer image versions are available.

It shows the version you are running next to the latest version, so you know exactly what to change in your scripts, and it can pull the new images for you.

## Features

- Lists every running container with its image, current tag and digest.
- Shows the latest available version only when it is newer than what is running.
- **Groups containers by app.** Containers launched together (for example `backend.penpot`, `frontend.penpot`, `mcp.penpot`) are versioned as one unit, so you never update one component to a release that doesn't match the others.
- Shows the app's icon, taken from the image's metadata.
- One-click **Pull images** for an update, with a confirmation and progress.
- Configurable check frequency and a **Launch at startup** option.
- Writes a JSON report and has a headless mode, so scripts can read the results.

## Requirements

- macOS 14 or later
- Apple's `container` CLI, installed and running (`container list` should work)
- Xcode to build it (developed with Xcode 27)

## Build and run

```bash
git clone <this repo>
cd ContainerWatch
xcodebuild -project ContainerWatch.xcodeproj -scheme ContainerWatch -configuration Release -derivedDataPath build build
open build/Build/Products/Release/ContainerWatch.app
```

Or open `ContainerWatch.xcodeproj` in Xcode and press Run. The app has no Dock icon; look for the box icon in the menu bar. A number next to it is how many updates are available.

To use **Launch at startup**, copy the built app to `/Applications` first and tick the box from that copy. Login items remember the app's location.

The app is not sandboxed, because it has to run the `container` CLI. It is signed ad hoc for local use.

## How versions are checked

| Image tag | What is compared |
| --- | --- |
| Numeric (`2.18`, `v1.4.2`, `16-alpine`) | The registry's tag list. It finds the newest tag of the same shape, and reports a newer major version separately. |
| Floating (`latest`, `2`, `15`) | The registry's digest for that tag against the digest you are running ("new build"). |
| Pinned by digest | Not checked. |

Registry lookups are anonymous, so public registries (Docker Hub, ghcr.io and similar) work. Private registries that need a login show "Check failed".

### Apps and dependencies

Containers are grouped by their network, or by the part of the name after the dot (`backend.penpot` belongs to `penpot`). Within a group:

- **Components** are the images from the same publisher namespace (for example everything under `penpotapp/`). They share one version. A release is only offered if it is published for **every** component. If a release exists for some but not all, the app tells you which are missing instead of offering it.
- **Dependencies** are the other images in the group (Postgres, Valkey, a proxy). Their versions are set by the app's own release, so they are listed but never offered as separate updates. Check the app's release notes before changing them.

## Updating

The **Pull image(s)…** button runs `container image pull` for each component, one at a time, and stops at the first failure. It only downloads images. **Running containers are not restarted**, so after pulling, restart them with your own script to use the new version.

## Settings

- **Check for updates every:** 5, 15 or 30 minutes, 1 hour, 1 day, 1 week, 1 month, or a custom interval. This is how long a registry result is trusted before the image is looked up again. The list of running containers itself refreshes about every 5 minutes. The default is 1 hour.
- **Launch at startup:** registers the app as a login item.
- The refresh button in the popover always checks the registries immediately.

## Scripting

Every scan writes `~/Library/Application Support/ContainerWatch/updates.json`.

You can also run the app binary directly. It scans once, prints the result and exits without showing any UI:

```bash
ContainerWatch.app/Contents/MacOS/ContainerWatch --report   # human-readable, with pull commands
ContainerWatch.app/Contents/MacOS/ContainerWatch --json     # same data as updates.json
```

Example `--report` output:

```
UPDATE  app penpot  2.18 -> 2.19
        container image pull docker.io/penpotapp/backend:2.19
        container image pull docker.io/penpotapp/exporter:2.19
        container image pull docker.io/penpotapp/frontend:2.19
        container image pull docker.io/penpotapp/mcp:2.19
        dependencies (version set by penpot, not updated separately):
          postgres.penpot  docker.io/library/postgres:15
UPDATE  flaresolverr  ghcr.io/flaresolverr/flaresolverr:latest  new build 139dfee1c6f8 -> c80ae007ce2c
        container image pull ghcr.io/flaresolverr/flaresolverr:latest
```

The JSON has these top-level keys:

- `checkedAt`: when the scan ran (ISO 8601).
- `apps`: one entry per app, with `name`, `currentVersion`, `latestVersion`, `newerMajorVersion`, `updateAvailable`, `notes`, `pullReferences`, `components` and `dependencies`.
- `standalone`: containers that aren't part of an app.
- `containers`: every container in one flat list, each with `app` and `role` (`component`, `dependency` or `standalone`).

Each container entry has `container`, `image`, `currentReference`, `currentTag`, `currentDigest`, `status`, `updateAvailable`, `latestTag`, `latestDigest`, `newerMajorTag`, `pullReference` and `error`. Use `pullReference` to get the exact image to pull.

For example, to list everything to pull:

```bash
ContainerWatch.app/Contents/MacOS/ContainerWatch --json | jq -r '.apps[].pullReferences[], (.standalone[] | select(.updateAvailable) | .pullReference)'
```

## Icons

Icons are fetched once and cached in `~/Library/Caches/ContainerWatch/icons`. Official Docker images use Docker's published logo; others use the GitHub owner named in the image's `org.opencontainers.image.source` or `.url` label. Images with neither show a generic box. This is the only other network traffic besides registry lookups.

## Project layout

| File | Purpose |
| --- | --- |
| `ContainerWatchApp.swift` | App entry point, menu bar item and popover, headless `--report` / `--json` mode |
| `ContainerCLI.swift` | Wrapper around the `container` command |
| `RegistryClient.swift` | Minimal registry client: tag lists and manifest digests |
| `ContainerMonitor.swift` | Grouping into apps and the update logic |
| `Models.swift` | Image references, tag versions and result types |
| `Store.swift` | Observable app state, check schedule and pull progress |
| `Report.swift` | Text and JSON output |
| `MenuView.swift`, `AppGroupView.swift`, `PullControl.swift` | The popover UI |
| `IconStore.swift` | Icon lookup and caching |
| `CheckInterval.swift` | Check frequency options |

## Limitations

- Private registries that require authentication aren't supported.
- Only running containers are listed.
- The app can pull images but doesn't restart containers, because it can't know how your containers were launched.
- Version checks assume tags follow a numeric pattern. Unusual tag schemes fall back to digest comparison or may not be detected.
