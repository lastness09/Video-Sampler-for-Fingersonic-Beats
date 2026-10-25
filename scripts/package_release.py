#!/usr/bin/env python3
"""Build and package the AUv3 app, source, and offline English instructions."""

import argparse
from datetime import datetime
import hashlib
import html
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import subprocess
import tempfile
import zipfile
from zoneinfo import ZoneInfo


ROOT = Path(__file__).resolve().parent.parent
BUILT_APP = ROOT / '.build/ReleaseDerivedData/Build/Products/Release/Video Sampler.app'


def run(*args):
    return subprocess.run([str(arg) for arg in args], check=True, text=True,
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT).stdout.strip()


def sha256(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def inline(text):
    escaped = html.escape(text)
    return re.sub(r'https://[^\s<]+', lambda m: f'<a href="{m[0]}">{m[0]}</a>', escaped)


def render_manual(markdown):
    """Render the small documented Markdown subset used by our offline guide."""
    blocks, list_kind, in_code, in_table = [], None, False, False
    for line in markdown.splitlines():
        if line.startswith('```'):
            blocks.append('</code></pre>' if in_code else '<pre><code>')
            in_code = not in_code
            continue
        if in_code:
            blocks.append(html.escape(line) + '\n')
            continue
        if line.startswith('|'):
            if re.fullmatch(r'[|\s:-]+', line):
                continue
            cells = [inline(cell.strip()) for cell in line.strip('|').split('|')]
            tag = 'td' if in_table else 'th'
            if not in_table:
                blocks.append('<div class="table"><table>')
                in_table = True
            blocks.append('<tr>' + ''.join(f'<{tag}>{cell}</{tag}>' for cell in cells) + '</tr>')
            continue
        if in_table:
            blocks.append('</table></div>')
            in_table = False
        item = re.match(r'^(?:- |\d+\. )(.+)', line)
        kind = ('ul' if line.startswith('- ') else 'ol') if item else None
        if list_kind and list_kind != kind:
            blocks.append(f'</{list_kind}>')
            list_kind = None
        if kind:
            if list_kind is None:
                blocks.append(f'<{kind}>')
                list_kind = kind
            blocks.append(f'<li>{inline(item[1])}</li>')
        elif line.startswith('#'):
            level = len(line) - len(line.lstrip('#'))
            blocks.append(f'<h{level}>{inline(line[level:].strip())}</h{level}>')
        elif line.strip():
            blocks.append(f'<p>{inline(line)}</p>')
    if list_kind:
        blocks.append(f'</{list_kind}>')
    if in_table:
        blocks.append('</table></div>')
    return '''<!doctype html>
<html lang="en"><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Video Sampler · Installation and User Guide</title>
<style>
*{box-sizing:border-box}body{margin:0;background:#edf3f6;color:#1c2939;
font:16px/1.75 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
article{max-width:960px;margin:36px auto;padding:42px 54px;background:white;
border-radius:20px;box-shadow:0 12px 46px #18304812;border-top:8px solid #1765ec}
h1{font-size:32px;line-height:1.25;letter-spacing:-1px;color:#1055c2}
h2{font-size:23px;margin:38px 0 14px;border-bottom:1px solid #e1e9ee;padding-bottom:8px}
h3{font-size:18px;margin:26px 0 10px}p{margin:12px 0}li{padding:3px 0}
a{color:#145bcb;overflow-wrap:anywhere}pre{white-space:pre-wrap;overflow-wrap:anywhere;
background:#132234;color:#e0fff8;padding:18px 22px;border-radius:10px;line-height:1.55}
.table{overflow-x:auto}table{border-collapse:collapse;width:100%;margin:16px 0}
td,th{text-align:left;border-bottom:1px solid #dfE7ed;padding:9px 15px}
th{background:#eef4fd;color:#174b95}tr:nth-child(even){background:#f8fafc}
@media(max-width:650px){article{margin:0;padding:24px 20px;border-radius:0}h1{font-size:27px}}
@media print{body{background:white}article{margin:0;padding:0;box-shadow:none;border:0}
h2,h3{break-after:avoid}tr,pre{break-inside:avoid}a{color:inherit}}
</style><article>''' + '\n'.join(blocks) + '</article></html>\n'


def add_instructions(destination, markdown):
    destination.mkdir(parents=True, exist_ok=True)
    (destination / 'INSTALL_AND_USER_GUIDE.html').write_text(render_manual(markdown), encoding='utf-8')
    plain = re.sub(r'^#{1,6} ', '', markdown, flags=re.MULTILINE)
    plain = re.sub(r'^```.*\n?', '', plain, flags=re.MULTILINE)
    (destination / 'INSTALL_AND_USER_GUIDE.txt').write_text(plain, encoding='utf-8')


def manifest(directory, filename):
    files = sorted(path for path in directory.rglob('*') if path.is_file() and path.name != filename)
    content = ''.join(f'{sha256(path)}  {path.relative_to(directory).as_posix()}\n' for path in files)
    (directory / filename).write_text(content, encoding='utf-8')


def archive(directory, target):
    # zipfile writes Unicode names with the UTF-8 flag and preserves Unix modes.
    with zipfile.ZipFile(target, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as bundle:
        for path in [directory, *sorted(directory.rglob('*'))]:
            name = path.relative_to(directory.parent).as_posix()
            if path.is_symlink():
                entry = zipfile.ZipInfo(name)
                entry.create_system = 3
                entry.external_attr = (stat.S_IFLNK | 0o777) << 16
                bundle.writestr(entry, os.readlink(path).encode('utf-8'))
            else:
                bundle.write(path, name)
    with zipfile.ZipFile(target) as bundle:
        if bundle.testzip() is not None:
            raise RuntimeError(f'Corrupt archive: {target.name}')
        if any('.DS_Store' in name or 'xcuserdata' in name or '__MACOSX' in name for name in bundle.namelist()):
            raise RuntimeError(f'Unwanted metadata in {target.name}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--skip-build', action='store_true', help='Package the existing ReleaseDerivedData build')
    parser.add_argument('--validation-note', type=Path, help='Optional actual test results to include verbatim')
    args = parser.parse_args()
    if not args.skip_build:
        subprocess.run(['zsh', str(ROOT / 'scripts/build_release.sh')], check=True)

    info = plistlib.loads((BUILT_APP / 'Contents/Info.plist').read_bytes())
    version, build = info['CFBundleShortVersionString'], info['CFBundleVersion']
    extension = BUILT_APP / 'Contents/PlugIns/VideoSamplerAU.appex'
    extension_info = plistlib.loads((extension / 'Contents/Info.plist').read_bytes())
    for source in [ROOT / 'VideoSamplerHost/Info.plist', ROOT / 'VideoSamplerAU/Info.plist']:
        source_info = plistlib.loads(source.read_bytes())
        if (source_info['CFBundleShortVersionString'], source_info['CFBundleVersion']) != (version, build):
            raise RuntimeError('Source and built app versions differ; rebuild first')
    if (extension_info['CFBundleShortVersionString'], extension_info['CFBundleVersion']) != (version, build):
        raise RuntimeError('App and extension versions differ')
    run('codesign', '--verify', '--deep', '--strict', BUILT_APP)
    executables = [BUILT_APP / 'Contents/MacOS/Video Sampler', extension / 'Contents/MacOS/VideoSamplerAU']
    for executable in executables:
        run('lipo', executable, '-verify_arch', 'arm64', 'x86_64')
    if not (BUILT_APP / 'Contents/Resources' / (info['CFBundleIconFile'] + '.icns')).is_file():
        raise RuntimeError('App icon is missing')

    markdown = (ROOT / 'docs/INSTALL.md').read_text(encoding='utf-8')
    if f'Version: {version} (build {build})' not in markdown:
        raise RuntimeError('Manual version differs from the built app; update the manual first')
    output = ROOT / 'dist' / f'VideoSampler-{version}-macOS'
    output.mkdir(parents=True, exist_ok=False)
    timestamp = datetime.now(ZoneInfo('Asia/Shanghai')).strftime('%Y-%m-%d %H:%M %z')
    report = f'''Video Sampler Release Verification
Version: {version} (build {build})
Packaged: {timestamp}
Format: macOS AUv3 Instrument, aumu / vsmr / FgSn
Minimum system: macOS {info['LSMinimumSystemVersion']}
Packaging environment: macOS {run('sw_vers', '-productVersion')} / {run('uname', '-m')}
Build tools: {run('xcodebuild', '-version').replace(chr(10), ' / ')}
Matching app and extension bundle versions: PASS
App and extension arm64 + x86_64 architecture checks: PASS
Nested code-signature integrity: PASS
App icon resource: INCLUDED
Signing: ad hoc; no Developer ID distribution signature or Apple notarization.
Each ZIP is checked for CRC errors. After extraction, app signatures and executable SHA-256 hashes are checked again.

The following are only claimed as tested when explicitly documented in the additional results:
DSP, video decoding, offline bounce, project-state restoration, auval, and hardware/host compatibility.
The default packaging process does not launch Logic or run those regression tests automatically.
'''
    if args.validation_note:
        report += '\nAdditional results for this release\n' + args.validation_note.read_text(encoding='utf-8')

    with tempfile.TemporaryDirectory(prefix='video-sampler-package-', dir=ROOT / '.build') as temporary:
        staging = Path(temporary)
        complete = staging / f'VideoSampler-{version}-Complete'
        plugin = complete / '01-AUv3'
        source = complete / '02-Source'
        notes = complete / '03-Publishing'
        plugin.mkdir(parents=True)
        source.mkdir()
        notes.mkdir()
        run('ditto', '--norsrc', '--noextattr', '--noqtn', BUILT_APP, plugin / BUILT_APP.name)
        add_instructions(plugin, markdown)
        (plugin / 'READ_ME_FIRST.txt').write_text('''This AUv3 instrument is installed with the complete Video Sampler.app.
1. Quit Logic and drag the app into Applications.
2. Open it once. If blocked, use System Settings → Privacy & Security → Open Anyway after confirming the source.
3. Logic Software Instrument track → Instrument → AU Instruments → Fingersonic → Video Sampler → Stereo.
Keep the installed app intact. Nothing needs to go in the AUv2 Components folder.
See INSTALL_AND_USER_GUIDE.html for complete instructions. This build is not notarized by Apple.
''', encoding='utf-8')
        ignored = shutil.ignore_patterns('.DS_Store', 'xcuserdata', '*.xcuserstate', '__pycache__', '*.pyc')
        for name in ['VideoSampler.xcodeproj', 'VideoSamplerAU', 'VideoSamplerHost', 'Tests', 'scripts', 'docs']:
            shutil.copytree(ROOT / name, source / name, ignore=ignored)
        for name in ['README.md', '.gitignore']:
            shutil.copy2(ROOT / name, source / name)
        for name in ['LICENSE', 'LICENSE.md', 'NOTICE']:
            if (ROOT / name).is_file():
                shutil.copy2(ROOT / name, source / name)
        manifest(source, 'SOURCE-SHA256.txt')
        add_instructions(notes, markdown)
        shutil.copy2(ROOT / 'docs/RELEASE_POST.txt', notes / 'RELEASE_POST.txt')
        shutil.copy2(ROOT / 'docs/RELEASE_NOTES.md', notes / 'RELEASE_NOTES.md')
        for folder in [plugin, notes, output]:
            (folder / 'VERIFICATION.txt').write_text(report, encoding='utf-8')
        (complete / 'READ_ME_FIRST.txt').write_text(f'''Video Sampler for Fingersonic Beats v{version}
01-AUv3: ready-to-use container app and user guide.
02-Source: source code, Xcode project, tests, and build/packaging scripts.
03-Publishing: user guide, editable release post, release notes, and verification report.
End users only need 01-AUv3. The app is the AUv3 plug-in's installation container.
SHA256FILES.txt records file integrity; it is not an Apple signature or notarization.
''', encoding='utf-8')
        add_instructions(output, markdown)
        shutil.copy2(ROOT / 'docs/RELEASE_POST.txt', output / 'RELEASE_POST.txt')
        shutil.copy2(ROOT / 'docs/RELEASE_NOTES.md', output / 'RELEASE_NOTES.md')
        manifest(complete, 'SHA256FILES.txt')
        targets = [(plugin, f'VideoSampler-{version}-AUv3-macOS.zip'),
                   (source, f'VideoSampler-{version}-Source.zip'),
                   (complete, f'VideoSampler-{version}-Complete.zip')]
        for folder, name in targets:
            archive(folder, output / name)
        for _, name in [targets[0], targets[2]]:
            unpacked = staging / ('verify-' + name)
            run('ditto', '-x', '-k', output / name, unpacked)
            unpacked_app = next(unpacked.rglob('Video Sampler.app'))
            run('codesign', '--verify', '--deep', '--strict', unpacked_app)
            for executable in executables:
                relative = executable.relative_to(BUILT_APP)
                if sha256(unpacked_app / relative) != sha256(executable):
                    raise RuntimeError('Packaged binary differs from the verified build')
    (output / 'SHA256SUMS.txt').write_text(''.join(
        f'{sha256(path)}  {path.name}\n' for path in sorted(output.glob('*.zip'))), encoding='utf-8')
    print(f'Release ready: {output}')


if __name__ == '__main__':
    main()
