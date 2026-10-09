"""Package a compiled arm64 iOS device app. Source folders never count as an IPA."""
from pathlib import Path
import argparse
import hashlib
import json
import os
import plistlib
import re
import stat
import struct
import zipfile


def inspect_binary(data):
    if len(data) < 32 or data[:4] != b'\xcf\xfa\xed\xfe':
        raise ValueError('Compiled 64-bit Mach-O executable required')
    _, cpu, _, filetype, commands, commands_size, _, _ = struct.unpack_from('<8I', data)
    if cpu != 0x0100000C or filetype != 2:
        raise ValueError('An arm64 application executable is required')
    if commands_size > len(data) - 32:
        raise ValueError('Truncated Mach-O load commands')
    offset, platforms, signed = 32, [], False
    for _ in range(commands):
        if offset + 8 > 32 + commands_size:
            raise ValueError('Truncated Mach-O load command')
        command, size = struct.unpack_from('<2I', data, offset)
        if size < 8 or offset + size > 32 + commands_size:
            raise ValueError('Invalid Mach-O load command size')
        if command == 0x32:
            if size < 24:
                raise ValueError('Invalid LC_BUILD_VERSION')
            platforms.append(struct.unpack_from('<I', data, offset + 8)[0])
        if command == 0x1D:
            signed = True
        offset += size
    if platforms != [2]:
        raise ValueError('An iOS device build is required; simulator builds are rejected')
    return {'architecture': 'arm64', 'platform': 'iOS', 'has_code_signature_command': signed}


def package(app, output):
    app, output = Path(app), Path(output)
    if not app.is_dir() or app.suffix != '.app':
        raise ValueError('The compiled .app folder is missing')
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    executable = info.get('CFBundleExecutable', '')
    if not executable or Path(executable).name != executable:
        raise ValueError('Invalid application executable name')
    binary = app / executable
    data = binary.read_bytes()
    binary_info = inspect_binary(data)
    if not binary.stat().st_mode & 0o111:
        raise ValueError('The app binary is not executable')
    if info.get('CFBundleIdentifier') != 'kr.deliverytools.routeprobe':
        raise ValueError('Unexpected bundle identifier')
    if info.get('CFBundlePackageType') != 'APPL' or info.get('CFBundleSupportedPlatforms') != ['iPhoneOS']:
        raise ValueError('iPhoneOS app metadata is required')
    if set(info.get('UIDeviceFamily', [])) != {1, 2}:
        raise ValueError('Both iPhone and iPad device families are required')
    version, build = str(info.get('CFBundleShortVersionString', '')), str(info.get('CFBundleVersion', ''))
    if not re.fullmatch(r'\d+\.\d+(?:\.\d+)?', version) or not re.fullmatch(r'\d+', build):
        raise ValueError('Invalid app version/build number')
    output.mkdir(parents=True, exist_ok=True)
    target = output / f'DeliveryRouteProbe_{version}-{build}-unsigned.ipa'
    temporary = target.with_suffix('.ipa.tmp')
    prefix = 'Payload/' + app.name + '/'
    with zipfile.ZipFile(temporary, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for path in sorted(app.rglob('*')):
            item = prefix + str(path.relative_to(app))
            if path.is_symlink():
                if not path.resolve().is_relative_to(app.resolve()):
                    raise ValueError('An app symlink points outside the app bundle')
                entry = zipfile.ZipInfo(item)
                entry.create_system = 3
                entry.external_attr = (stat.S_IFLNK | 0o777) << 16
                archive.writestr(entry, os.readlink(path))
            elif path.is_file():
                archive.write(path, item)
    with zipfile.ZipFile(temporary) as archive:
        if archive.testzip() is not None or archive.read(prefix + executable) != data:
            raise ValueError('IPA integrity check failed')
        archived_info = plistlib.loads(archive.read(prefix + 'Info.plist'))
        if archived_info != info:
            raise ValueError('IPA metadata changed during packaging')
    temporary.replace(target)
    report = {'file': target.name, 'bytes': target.stat().st_size, 'sha256': hashlib.sha256(target.read_bytes()).hexdigest(),
              'bundle_identifier': info['CFBundleIdentifier'], 'version': version, 'build': build,
              'minimum_os': info.get('MinimumOSVersion'), 'devices': ['iPhone', 'iPad'],
              'binary': binary_info, 'signing': 'Built with code signing disabled; personal installation signing is separate',
              'source_commit': os.environ.get('GITHUB_SHA'), 'compiled_device_binary_present': True, 'device_launch_tested': False}
    (output / (target.stem + '.json')).write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(report, ensure_ascii=False))
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app')
    parser.add_argument('output')
    args = parser.parse_args()
    package(args.app, args.output)
