# Third-Party Notices

This file summarizes third-party code and dependencies distributed with this
repository. It is intended as a practical redistribution notice, not legal
advice.

## Project License

This repository is distributed with GPL-3.0 source in the active runtime
(`SquirrelAI/modules/aaahogex`). The repository-level license is therefore
GPL-3.0; see `LICENSE` for the full license text.

When redistributing this project:

- keep the complete source available;
- keep the root `LICENSE` file;
- keep this `THIRD_PARTY_NOTICES.md` file;
- keep third-party copyright/license headers in vendored files;
- preserve the license files under `LICENSES/`;
- state meaningful changes to GPL-covered third-party code.

## Vendored Runtime Code

### AAAHogEx

Source project: `AAAHogEx` / `HogeAI`

Upstream repository: `https://github.com/rei-artist/AAAHogEx`

License: GPL-3.0

License text included at:

- `LICENSE`
- `LICENSES/AAAHogEx-LICENSE`

Vendored files:

- `SquirrelAI/modules/aaahogex/air.nut`
- `SquirrelAI/modules/aaahogex/aystar.nut`
- `SquirrelAI/modules/aaahogex/estimator.nut`
- `SquirrelAI/modules/aaahogex/pathfinder.nut`
- `SquirrelAI/modules/aaahogex/place.nut`
- `SquirrelAI/modules/aaahogex/railbuilder.nut`
- `SquirrelAI/modules/aaahogex/road.nut`
- `SquirrelAI/modules/aaahogex/roadpathfinder.nut`
- `SquirrelAI/modules/aaahogex/route.nut`
- `SquirrelAI/modules/aaahogex/station.nut`
- `SquirrelAI/modules/aaahogex/tile.nut`
- `SquirrelAI/modules/aaahogex/trainroute.nut`
- `SquirrelAI/modules/aaahogex/utils.nut`
- `SquirrelAI/modules/aaahogex/water.nut`

Use in this project:

- road route construction;
- rail path and infrastructure construction;
- station, tile, terrain, route, vehicle, and estimator helpers;
- airport/terrain builder support.

Local changes:

- integrated as an active SquirrelAI runtime module stack;
- adapted references from the upstream AI controller context to SquirrelAI;
- used as infrastructure-building helpers rather than as a standalone AI;
- combined with SquirrelAI command handlers, rollback helpers, and bridge
  command protocol.

Obligations:

- distribute this combined source under GPL-3.0-compatible terms;
- include the full GPL-3.0 text;
- provide the complete corresponding source when conveying copies;
- keep notices and make local modifications clear.

### MinchinWeb MetaLibrary

Source project: MinchinWeb's MetaLibrary

Upstream repository: `https://github.com/MinchinWeb/openttd-metalibrary`

License: MinchinWeb MetaLibrary permission license

License text included at:

- `LICENSES/MinchinWeb-MetaLibrary-License.txt`

Vendored files:

- `SquirrelAI/modules/metalibrary/Array.nut`
- `SquirrelAI/modules/metalibrary/Constants.nut`
- `SquirrelAI/modules/metalibrary/Extras.nut`
- `SquirrelAI/modules/metalibrary/Lakes.nut`
- `SquirrelAI/modules/metalibrary/Line.Walker.nut`
- `SquirrelAI/modules/metalibrary/Log.nut`
- `SquirrelAI/modules/metalibrary/Marine.nut`
- `SquirrelAI/modules/metalibrary/Pathfinder.Ship.nut`
- `SquirrelAI/modules/metalibrary/Spiral.Walker.nut`

Project adapter files:

- `SquirrelAI/modules/metalibrary/cargo_provider.nut`
- `SquirrelAI/modules/metalibrary/ship_provider.nut`

Use in this project:

- ship pathfinding and buoy path construction;
- waterbody connectivity checks;
- marine, geometry, line/spiral walker, array, constants, logging, and helper
  functions required by the ship/water integration.

Local changes:

- vendored as direct runtime files rather than imported through OpenTTD's
  in-game library downloader;
- wrapped by provider files for SquirrelAI route-building calls;
- fallback behavior is provided by project adapter code where the pathfinder
  cannot produce a usable route.

Obligations:

- include the MetaLibrary copyright and permission notice;
- provide attribution in the normal place for third-party contributions;
- keep the no-warranty notice.

Important exclusion:

- MetaLibrary's LGPL-2.1 `Pathfinder.Road.nut` is not included in this public
  repository and is not runtime-loaded by `SquirrelAI/main.nut`.

## Python Runtime Dependencies

Python packages are installed from PyPI via `requirements.txt`; they are not
vendored in this repository.

| Package | Used by | License | Notes |
|---|---|---|---|
| `requests` | `bridge_runtime/llm/client.py` | Apache-2.0 | OpenAI-compatible HTTP client. |
| `pyOpenTTDAdmin` | `bridge_runtime/admin/connection.py` | MIT | OpenTTD admin port client. |

Optional native Gemini mode imports `google-genai` from the user's Python
environment when configured for that provider path. It is not vendored and is
left commented in `requirements.txt`; PyPI lists its license expression as
Apache-2.0.

If you later bundle Python wheels, source distributions, an executable build,
or a container image, include license notices for these packages and their
transitive dependencies as installed in that distribution.

## External Programs Not Bundled

OpenTTD is required at runtime but is not bundled in this repository.
OpenTTD is a separate project licensed under GPL-2.0. Users install it
separately from `https://www.openttd.org/`.

An OpenAI-compatible chat-completions provider is also required for live LLM
play. No model weights or LLM provider SDKs are bundled here.
