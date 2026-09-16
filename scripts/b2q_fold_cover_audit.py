#!/usr/bin/env python3
"""Check stock config survived all UN1CA patches; no claim of runtime support."""
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import sys
import xml.etree.ElementTree as ET
import zipfile


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def resolve(work, rel):
    parts = PurePosixPath(rel).parts
    if not parts or rel.startswith('/') or '..' in parts:
        raise ValueError(f'Unsafe relative path: {rel}')
    partition, *tail = parts
    if partition not in {'system', 'system_ext', 'product', 'vendor', 'odm'} or not tail:
        raise ValueError(f'Unknown partition path: {rel}')
    if partition == 'system':
        if tail[0] == 'system':
            tail = tail[1:]
        if tail and tail[0] in {'product', 'system_ext', 'vendor', 'odm'}:
            partition, *tail = tail
    if partition == 'system':
        roots = [work / 'system/system', work / 'system']
    else:
        roots = [work / partition, work / 'system/system' / partition,
                 work / 'system' / partition]
    root = next((p for p in roots if p.is_dir()), None)
    if root is None or not tail:
        raise ValueError(f'Partition root unavailable: {rel}')
    dst = root.joinpath(*tail)
    if not dst.resolve().is_relative_to(work.resolve()):
        raise ValueError(f'Path escapes workdir: {rel}')
    return dst


def features(path):
    result = {}
    for node in ET.parse(path).getroot():
        if node.tag.startswith('SEC_FLOATING_FEATURE_') and re.search(
                r'(?:FOLD(?!ER)|FLIP|SUB_?DISPLAY|COVER_DISPLAY|COVER_SCREEN|HINGE|FLEX_MODE|MULTI_DISPLAY)', node.tag):
            if node.tag in result:
                raise ValueError(f'Duplicate floating feature: {node.tag}')
            result[node.tag] = (node.text or '').strip()
    return result


def verify(work, stage, report_path):
    report = {'status': 'failed', 'files': [], 'features': {}, 'dex_markers': {},
              'warnings': [], 'errors': [],
              'scope': 'Workdir configuration only; hardware and framework behavior untested.'}
    errors = report['errors']
    try:
        stock_ff = stage / 'stock-floating-feature.xml'
        if digest(stock_ff) != (stage / 'stock-floating-feature.sha256').read_text().strip():
            raise ValueError('Stock floating feature reference checksum mismatch')
        expected = features(stock_ff)
        actual = features(resolve(work, 'system/system/etc/floating_feature.xml'))
        if not expected:
            errors.append('No fold/cover floating features identified in stock F711B')
        for key, value in sorted(expected.items()):
            report['features'][key] = {'stock': value, 'workdir': actual.get(key)}
            if actual.get(key) != value:
                errors.append(f'Floating feature mismatch after common patches: {key}')
        rows = (stage / 'manifest.tsv').read_text().splitlines()
        if not rows:
            errors.append('Empty fold/cover manifest')
        for row in rows:
            rel, sha, reason = row.split('\t', 2)
            dst = resolve(work, rel)
            src = stage / 'root' / rel
            if digest(src) != sha:
                errors.append(f'Staging checksum mismatch: {rel}')
            if not dst.is_file():
                errors.append(f'Not installed: {rel}')
                continue
            final_sha = digest(dst)
            report['files'].append({'stock': rel, 'destination': str(dst.relative_to(work)),
                                    'sha256': final_sha, 'matches_stock': final_sha == sha})
            if final_sha != sha:
                if reason == 'stock Samsung Flex mode panel application':
                    report['warnings'].append(f'Donor Flex panel retained, compatibility untested: {rel}')
                else:
                    errors.append(f'Installed config changed after target patch: {rel}')
            if dst.suffix == '.xml':
                ET.parse(dst)
        # Markers are clues, not proof that a class/feature is present or enabled.
        markers = [b'DeviceStateProvider', b'DeviceStateManager', b'FoldState',
                   b'SubScreen', b'CoverScreen', b'ControlPanel']
        for rel in ['system/system/framework/framework.jar',
                    'system/system/framework/services.jar',
                    'system/system/priv-app/SystemUI/SystemUI.apk']:
            archive = resolve(work, rel)
            entry = {'readable_dex': 0, 'markers': []}
            if archive.is_file():
                try:
                    with zipfile.ZipFile(archive) as z:
                        found = set()
                        for name in z.namelist():
                            if re.fullmatch(r'classes(?:\d+)?\.dex', name):
                                entry['readable_dex'] += 1
                                data = z.read(name)
                                found.update(m.decode() for m in markers if m in data)
                        entry['markers'] = sorted(found)
                except (OSError, zipfile.BadZipFile) as exc:
                    entry['error'] = str(exc)
            report['dex_markers'][rel] = entry
    except (OSError, ValueError, ET.ParseError) as exc:
        errors.append(str(exc))
    report['status'] = 'failed' if errors else 'passed'
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, indent=2) + '\n')
    print(f'B2Q-FOLD-COVER: final workdir audit {report["status"]}: {report_path}')
    for error in errors:
        print('ERROR: ' + error, file=sys.stderr)
    return bool(errors)


if __name__ == '__main__':
    try:
        if len(sys.argv) == 4 and sys.argv[1] == 'resolve':
            print(resolve(Path(sys.argv[2]), sys.argv[3]))
        elif len(sys.argv) == 5 and sys.argv[1] == 'verify':
            sys.exit(verify(*map(Path, sys.argv[2:])))
        else:
            sys.exit('Usage: b2q_fold_cover_audit.py resolve WORK REL | verify WORK STAGE REPORT')
    except ValueError as exc:
        sys.exit(str(exc))
