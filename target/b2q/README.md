# Galaxy Z Flip3 5G (SM-F711B / b2q)

Status: **bring-up target; not certified for public flashing yet**.

Verified in source configuration:

- target model: SM-F711B
- codename: b2q
- platform: SM8350 / lahaina
- first API level: 30
- Android 15 target firmware / SDK 35
- boot and recovery partition size: 100663296 bytes
- dtbo partition size: 25165824 bytes (confirmed from F711BXXSIJZE5 padded image)
- super size: 9126805504 bytes
- dynamic group: samsung_dynamic_partitions, 9122611200 bytes
- logical partitions: system, vendor, product, odm

Before the first flash, run `scripts/audit_b2q_firmware.sh` against the firmware
extracted by UN1CA and complete the test matrix in `docs/B2Q_PORTING.md`.

## Camera feature data

`scripts/prepare_b2q_camera.sh` copies `camera-feature.xml` from the already extracted stock SM-F711B firmware into `target/b2q/camera/` immediately before `make_rom`. The file is generated per firmware version rather than guessed or copied from another model.

### Samsung Camera quick-setting guard

`target/b2q/patches/camera_quick_setting_guard` removes only the unsupported top-level `BACK_CAMERA_PICTURE_SIZE_TOGGLE_MENU` entry from the One UI 8 donor `QUICK_SETTING_MENU`. The existing list builder filters the injected null value; the submenu definition, camera IDs, lenses, resolutions and stock SM-F711B `camera-feature.xml` remain unchanged.


The `overlay/` directory is generated before `make_rom` from the stock F711B
product framework RRO by `scripts/prepare_b2q_overlay.sh`; it is not copied from
another target. Current UN1CA expects flat XML files such as
`target/b2q/overlay/dimens.xml`, so the helper flattens the decoded
`res/values/*.xml` files instead of keeping an APK-style `res/values` tree.

### Geometria przycisku zasilania / AOD

Helper overlay odczytuje stockową wartość
`physical_power_button_center_screen_location_y` i normalizuje integralne
`*.0px` do kanonicznego `*px`. Dla b2q `target/b2q/patches/aod_clock_transition/customize.sh` usuwa
wyłącznie kosmetyczny AOD clock transition w aktywnym workdir; samo AOD pozostaje włączone.
Stockowy `floating_feature.xml` jest przywracany automatycznie po `make_rom`
oraz po przerwaniu buildu.

The device framework VINTF matrix is generated from the currently extracted
SM-F711B firmware by `scripts/prepare_b2q_vintf.sh` and stored under `vintf/`
before the common UN1CA VINTF module runs.


The camera guard also protects `getIndicatorItemList()` by skipping commands whose `mQuickSettingViewItemMap` lookup returns null before `Q2/p.a()` is called.

## Fold / cover display / Flex mode

Before `make_rom`, `scripts/prepare_b2q_fold_cover.sh` copies the real SM-F711B device-state and display configuration into `target/b2q/fold-cover/`, preserving partition-relative paths and SHA-256 hashes. It also stages the stock Samsung Flex mode panel (`ControlPanel.apk`, package `com.samsung.controlpanel`) when that APK exists in the target firmware. The `fold_cover_stock` target patch restores those files into the active workdir and only uses the Android 15 ControlPanel when the Android 16 donor does not already provide one. Core donor APKs such as SystemUI, Settings and AlwaysOnDisplay are not downgraded.
