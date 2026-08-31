# Changelog

## Unreleased

- Update LuaJIT to the 2026-07-20 v2.1 head (matches upstream SimpleGraphic), adding the compound
  assignment syntax (`+=` etc.) that Path of Building 2.67+ uses — fixes "Error loading main
  script: Modules/Main.lua: '=' expected near '+'" after an in-app update

## mac-v0.1.3 (2026-08-04)

- Fix updater (thanks @ocombe)
- Update bundled Path of Building to 2.66.2

## mac-v0.1.2 (2026-05-17)

- Fix failure to boot on some machines due to missing dependency (OpenSSL)

## mac-v0.1.1 (2026-05-06)

- Fix an issue where startup errors would not show in the in-app popup

## mac-v0.1.0 (2026-04-18)

- Initial release
