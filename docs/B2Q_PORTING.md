# UN1CA bring-up: Galaxy Z Flip3 5G SM-F711B (b2q)

## Scope

This adds a self-contained target (`target/b2q`) and platform (`platform/sm8350`)
for the international Galaxy Z Flip3 5G. It deliberately avoids modifying UN1CA
core scripts, making future merges from the original `sixteen` branch simpler.
UN1CA discovers targets by enumerating directories, so no central device list is
required. The existing build workflow should also discover `b2q` automatically.

## Installation into your fork

From the root of your UN1CA fork:

```bash
unzip UN1CA-b2q-port.zip
cd UN1CA-b2q-port
./install.sh /path/to/your/UN1CA
```

Or apply the Git patch:

```bash
git am --3way /path/to/0001-add-galaxy-z-flip3-b2q-support.patch
```

## Firmware identity

UN1CA/FUS requires `Model/CSC/IMEI-or-serial`. Prefer your own SM-F711B identity:

```bash
export B2Q_TARGET_FIRMWARE='SM-F711B/EUX/YOUR_FULL_IMEI_OR_SERIAL'
```

`B2Q_TARGET_FIRMWARE` overrides only the b2q target tuple during UN1CA configuration generation. The qssi donor `SOURCE_FIRMWARE` is left exactly as defined by upstream UN1CA.

The checked-in value follows the pattern used by existing UN1CA targets, but it
is only a placeholder and may stop working with FUS.

## Validate, download, extract and audit

The build wrapper performs this sequence automatically and stops before
`make_rom` when the audit reports a definite error:

```bash
export B2Q_TARGET_FIRMWARE='SM-F711B/EUX/YOUR_FULL_IMEI_OR_SERIAL'
scripts/build_b2q.sh
```

The wrapper runs static validation, dependency build, firmware download,
firmware extraction, preparation of target camera/DVFS/RRO files from the stock SM-F711B firmware, the b2q firmware audit and only then `make_rom`. A clear
partition overflow, codename mismatch or dynamic-group mismatch aborts it.

For a standalone inspection:

```bash
scripts/validate_b2q.sh
source buildenv.sh b2q
unica build_dependencies
unica download_fw
unica extract_fw
scripts/audit_b2q_firmware.sh out/fw/SM-F711B_EUX
```

The exact extracted directory may differ; pass the directory containing the
unpacked b2q partitions and properties.

Confirmed from the padded images extracted from SM-F711B/EUX Android 15 firmware `F711BXXSIJZE5`:

- `boot`: 100663296 bytes;
- `vendor_boot`: 100663296 bytes;
- `dtbo`: 25165824 bytes.

Items that still must be confirmed before flash:

- `cache` partition size from PIT;
- current dynamic partition metadata (`lpdump`);
- stock fstab filesystem types and AVB chain;
- feature values marked as a conservative baseline in `target/b2q/config.sh`;
- whether Android 16 QSSI from the `sixteen` branch passes VINTF against the
  Android 15 / board-API-30 vendor image.

## Build

```bash
export B2Q_TARGET_FIRMWARE='SM-F711B/EUX/YOUR_FULL_IMEI_OR_SERIAL'
scripts/build_b2q.sh
```

Use `--skip-deps` after tools have already been built. Use `--incremental` only
when you did not change `platform/sm8350`; the upstream work-dir hash currently
tracks `unica` and `target`, not platform files.

## First-flash gate

Do not distribute or flash a build until all entries below pass on an expendable
test device with a complete stock backup and a known Odin recovery path.

- ZIP installer refuses every model except SM-F711B.
- Installer refuses pre-Android-15 bootloaders.
- `lpdump` values exactly match target configuration.
- `boot`, `vendor_boot`, `dtbo` images fit their physical partitions.
- Recovery mounts metadata/data/efs and all four logical partitions.
- VINTF check passes; no vendor interface incompatibility at boot.
- Main display and cover display render at correct rotation, density and cutout.
- Fold/unfold, hinge angle, continuity and Flex Mode work.
- Touch works over the fold and while partially folded.
- RIL, calls, SMS, mobile data, VoLTE/VoWiFi and eSIM work.
- Wi-Fi, hotspot, Bluetooth, NFC and GNSS work.
- Both speakers, microphones, cameras and video recording work.
- Side fingerprint, face unlock, proximity, light, gyro and hall sensors work.
- USB, charging, wireless charging and reverse wireless charging work.
- Encryption survives reboot; factory reset works.
- Deep sleep, thermal control and sustained-load behavior are acceptable.
- Camera cover-screen preview and Samsung foldable features work.
- No rollback, AVB, dm-verity or vbmeta error is present in logs.

## Updating from the original project

Manual safe merge:

```bash
scripts/sync_upstream.sh
```

Preview only:

```bash
scripts/sync_upstream.sh --dry-run
```

A scheduled GitHub Action is included. It merges the original `sixteen` branch
into an automation branch, runs the b2q validator and opens/updates a pull
request. Keep branch protection enabled and require real-device testing before
merging a release.

## Recovery

Unlocking/flashing trips Knox permanently and normally wipes user data. Keep the
full current SM-F711B Odin firmware, Samsung USB drivers and a tested Download
Mode procedure available. Never attempt to recover a failed first boot by
flashing images whose partition sizes were not confirmed from the same firmware.

## Odporność pobierania w kreatorze 1.6.1

Wrapper nadal wywołuje oryginalne `scripts/download_fw.sh`. Najpierw uruchamia je z `--ignore-source`, aby FUS zaakceptował i pobrał firmware docelowe SM-F711B, a dopiero później z `--ignore-target` pobiera dawcę qssi. Każdy etap ma do trzech prób. Po zbudowaniu zależności zwiększany jest wyłącznie timeout zapytania `version.xml`; `SOURCE_FIRMWARE` nie jest podmieniane.

Oryginalny format firmware UN1CA rozróżnia pełny 15-cyfrowy IMEI i numer seryjny. Kreator przekazuje jeden z tych identyfikatorów bez skracania. Sam 8-cyfrowy TAC nie jest używany w tej warstwie integracji, ponieważ mógłby zostać potraktowany jak numer seryjny.

## Generated camera feature file

The common UN1CA camera patch may require `target/b2q/camera/camera-feature.xml`. The b2q wrapper now prepares it from the extracted stock SM-F711B firmware before `make_rom`:

```bash
scripts/prepare_b2q_camera.sh out/fw/SM-F711B_EUX
```

The helper searches known Samsung camera-data locations, preserves the stock XML byte-for-byte and aborts instead of inventing unsupported camera flags. When target firmware changes, the generated file is refreshed automatically.


### Samsung Camera quick-setting list guard

Runtime inspection of the installed One UI 8 donor APK showed that the old `PhotoQuickSettingController.getPictureSizeMenu()` patch was present but the crash still occurred earlier, while `QuickSettingPresenter` iterated `CommandIdMap.QUICK_SETTING_MENU`. The donor list selected `BACK_CAMERA_PICTURE_SIZE_TOGGLE_MENU` whenever multi-high-resolution was false, even when back high resolution itself was unsupported. The resource depot correctly omitted that descriptor and threw `Resources$NotFoundException`.

The b2q module now replaces only the first, top-level toggle load in the static command-map initializer with null. Samsung Camera's existing list helper filters null entries. The later toggle reference that defines the submenu remains unchanged. The module checks the exact feature/list context and aborts on an unexpected APK layout.

### Target DVFS data

The common UN1CA DVFS patch expects device-specific data under
`target/b2q/dvfs/`, in particular the generic `siop_model.xml`. On current
SM-F711B firmware the SIOP document is embedded in stock
`SamsungDeviceHealthManagerService.apk`, rather than exposed as a standalone
`system/etc` file. `scripts/prepare_b2q_dvfs.sh` first checks legacy standalone
locations, then inspects the target APK resources and, when necessary, decodes
that APK with UN1CA's local `apktool`. Only a valid stock `siop_document` from
the extracted F711B firmware is accepted; a policy from another model is never
substituted.


## Product framework RRO

`scripts/prepare_b2q_overlay.sh` decodes the stock
`framework-res__b2qxxx__auto_generated_rro_product.apk` from the extracted
SM-F711B firmware and extracts its unqualified `res/values/*.xml` files into
the flat target contract `target/b2q/overlay/*.xml`. Current UN1CA reads files
such as `target/b2q/overlay/dimens.xml` directly; keeping an APK-style nested
`overlay/res/values` tree causes the RRO module to report the resource as
missing. The generated flat overlay is refreshed automatically when the stock
RRO SHA-256 changes.

### Geometria przycisku zasilania / AOD

`scripts/prepare_b2q_overlay.sh` odczytuje niezerową wartość `physical_power_button_center_screen_location_y` ze stockowego firmware SM-F711B. Integralny zapis apktool, np. `620.0px`, jest normalizowany do `620px`, bez zmiany współrzędnej. Targetowy moduł `target/b2q/patches/aod_clock_transition/customize.sh` usuwa tylko token AOD clock transition z aktywnego workdir po `create_work_dir`; samo AOD pozostaje włączone, a rozpakowane firmware targetu nie jest modyfikowane.

## Device VINTF matrix

Before `make_rom`, `scripts/prepare_b2q_vintf.sh` locates and validates the
stock `compatibility_matrix.device.xml` from the extracted SM-F711B system
partition. The exact file is copied to `target/b2q/vintf/` with a source path
and SHA-256 marker. Do not replace it with a matrix from another device or an
empty permissive placeholder.


## Foldable PackageManager feature parity

Runtime testing showed that stock SM-F711B does not declare the experimental `com.sec.feature.dual_lcd` / `com.sec.feature.folder_type` PackageManager features, so that path is no longer used. `scripts/prepare_b2q_fold_cover.sh` instead stages the target's real `*/etc/devicestate/*.xml`, `*/etc/displayconfig/*.xml`, input/display port associations and hinge-angle feature XMLs. It also stages Samsung's foldable-only Flex mode panel app (`ControlPanel.apk`, package `com.samsung.controlpanel`) when it exists in the extracted target firmware. `target/b2q/patches/fold_cover_stock/customize.sh` verifies SHA-256 values and restores those files into the active workdir. If the Android 16 donor already contains its own Flex panel, the donor copy is preserved. Android 15 SystemUI, Settings and AlwaysOnDisplay APKs are deliberately not transplanted.
