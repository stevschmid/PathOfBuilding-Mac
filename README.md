# PathOfBuilding-Mac

Unofficial macOS port of Path of Building, an offline build planner for Path of Exile.

## Features

* Faithful port of Path of Building to macOS, with a focus on performance and user experience
* Supports both PoE 1 and PoE 2
* Native Apple Silicon (M1, M2 etc.) support
* Uses same engine as Windows (SimpleGraphic), with Metal backend via ANGLE
* Supports in-app updates (will update to latest version of the official PoB Lua core, i.e. passive tree etc.). No auto update of the app itself however.

## System requirements

* macOS 11 (Big Sur) or later
* Apple Silicon (M1+), Intel-based Macs are not supported

## Download

You can download the latest version from the [releases page](https://github.com/stevschmid/PathOfBuilding-Mac/releases).

* `PathOfBuilding-Mac.dmg` is the standalone app for Path of Building (Path of Exile 1).
* `PathOfBuilding-Mac-PoE2.dmg` is the standalone app for Path of Building (Path of Exile 2).

Download, open the DMG, drag the app to your Applications folder, and launch it from there.

## Credits

* [PathOfBuildingCommunity](https://github.com/PathOfBuildingCommunity) for the outstanding work on the upstream project
* [PR #98](https://github.com/PathOfBuildingCommunity/PathOfBuilding-SimpleGraphic/pull/98) by @velomeister for the Linux port that helped kickstart this project

## How to file issues

Please use this [repository](https://github.com/stevschmid/PathOfBuilding-Mac/issues) to report any bugs or suggest features (**do not use the official PoB repo**).
Please include what PathOfBuilding-Mac version you are using, plus your macOS version and which port you use (PoE 1 or PoE 2).

## License

[MIT](https://github.com/stevschmid/PathOfBuilding-Mac/blob/master/LICENSE)

For 3rd-party licenses of Path of Building, see [License.md](https://github.com/PathOfBuildingCommunity/PathOfBuilding/blob/dev/LICENSE.md).
