# Deus Airlock

Independent macOS isolation work based on **sing-box-for-apple**. The goal is
to route selected applications and the helpers they launch through one VPS,
retaining the OS per-app binding when the transport is unavailable.

**Development status:** fork/bootstrap and offline qualification. A running
tunnel does not yet mean Claude is isolated. Recursive-directory coverage,
helper attribution and fail-closed behavior require the runtime acceptance
gates; do not remove your working network tools on the strength of this build.

- [Build instructions](docs/build.md)
- [Upstream updates](docs/upstream.md)
- [Product contract and acceptance gates](docs/superpowers/specs/2026-11-18-deus-airlock.md)
- [Implementation plan](docs/superpowers/plans/2026-11-18-deus-airlock.md)
- [Actual execution evidence](docs/execution.md)
- [Core fork](https://github.com/d3pre5s/deus-airlock-core)
- [Darwin transport fork](https://github.com/d3pre5s/deus-airlock-tun)

## Upstream

Experimental iOS/macOS/tvOS client for sing-box, the universal proxy platform.

## Documentation

[SFI](https://sing-box.sagernet.org/installation/clients/sfi/) | [SFM](https://sing-box.sagernet.org/installation/clients/sfm/)

## License

```
Copyright (C) 2022 by nekohasekai <contact-sagernet@sekai.icu>

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program. If not, see <http://www.gnu.org/licenses/>.
```
