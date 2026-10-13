"""Select a stable installed SDK that can build Continued Processing (iOS 26+)."""
from pathlib import Path
import os, plistlib, re

choices = []
for app in Path('/Applications').glob('Xcode*.app'):
    try:
        version = plistlib.loads((app / 'Contents/version.plist').read_bytes())['CFBundleShortVersionString']
        parts = tuple(int(x) for x in version.split('.'))
        if parts[0] >= 26 and not re.search(r'beta|rc', app.name, re.I):
            choices.append((parts, app.resolve()))
    except (OSError, KeyError, ValueError):
        continue
if not choices:
    raise SystemExit('Xcode 26 or newer is required for real background collection.')
version, app = max(choices)
developer = str(app / 'Contents/Developer')
if os.environ.get('GITHUB_ENV'):
    with open(os.environ['GITHUB_ENV'], 'a') as env:
        env.write('DEVELOPER_DIR=' + developer + '\n')
print('Selected Xcode ' + '.'.join(map(str, version)) + ': ' + developer)
