#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
source "$ROOT/scripts/release-variant.sh"
source "$ROOT/packaging/doubao-driver/install/driver-naming.zsh"
# Retain fixtures. Never install a fixture in system HAL or delete a fixture.
WORK="$ROOT/.build/driver-naming-tests/$(/usr/bin/uuidgen)"
/bin/mkdir -p "$WORK"
"$ROOT/scripts/verify-doubao-driver.sh" "$RELEASE_OUTPUT_DIR/MiRemoteV2ch.driver" brand
"$ROOT/scripts/verify-doubao-driver.sh" "$RELEASE_OUTPUT_DIR/legacy/MiRemoteV2ch.driver" legacy
/usr/bin/xcrun clang -arch "$RELEASE_ARCH" "$ROOT/Tests/Fixtures/DriverProperties.c" \
  -framework CoreAudio -framework CoreFoundation -o "$WORK/driver-properties"
if /usr/bin/arch "-$RELEASE_ARCH" /usr/bin/true >/dev/null 2>&1; then
  "$WORK/driver-properties" "$RELEASE_OUTPUT_DIR/MiRemoteV2ch.driver/Contents/MacOS/MiRemoteV2ch" SayAll
  "$WORK/driver-properties" "$RELEASE_OUTPUT_DIR/legacy/MiRemoteV2ch.driver/Contents/MacOS/MiRemoteV2ch" "MiRemoteV 2ch"
else
  print "DRIVER PROPERTY PROBE SKIPPED: this Mac cannot execute $RELEASE_ARCH; run on a matching Mac."
fi
[[ "$(driver_naming_variant "$RELEASE_OUTPUT_DIR/MiRemoteV2ch.driver")" == brand ]]
[[ "$(driver_naming_variant "$RELEASE_OUTPUT_DIR/legacy/MiRemoteV2ch.driver")" == legacy ]]
/usr/bin/ditto "$RELEASE_OUTPUT_DIR/MiRemoteV2ch.driver" "$WORK/unmarked-brand.driver"
/usr/bin/plutil -remove SayAllNamingVariant "$WORK/unmarked-brand.driver/Contents/Info.plist"
/usr/bin/codesign --force --sign - --timestamp=none "$WORK/unmarked-brand.driver"
if driver_naming_variant "$WORK/unmarked-brand.driver"; then exit 1; fi
/usr/bin/ditto "$RELEASE_OUTPUT_DIR/legacy/MiRemoteV2ch.driver" "$WORK/unmarked.driver"
/usr/bin/plutil -remove SayAllNamingVariant "$WORK/unmarked.driver/Contents/Info.plist"
/usr/bin/codesign --force --sign - --timestamp=none "$WORK/unmarked.driver"
[[ "$(driver_naming_variant "$WORK/unmarked.driver")" == legacy ]]
/usr/bin/ditto "$RELEASE_OUTPUT_DIR/MiRemoteV2ch.driver" "$WORK/unknown.driver"
/usr/bin/plutil -replace SayAllNamingVariant -string unknown "$WORK/unknown.driver/Contents/Info.plist"
/usr/bin/codesign --force --sign - --timestamp=none "$WORK/unknown.driver"
if driver_naming_variant "$WORK/unknown.driver"; then exit 1; fi
/usr/bin/plutil -replace SayAllNamingVariant -string legacy "$WORK/unknown.driver/Contents/Info.plist"
if driver_naming_variant "$WORK/unknown.driver"; then exit 1; fi
if driver_naming_safe_directory "$WORK"; then exit 1; fi
# The fixture volume is user-owned. Bypass only root ownership for enumeration.
functions[fixture_original_safe_directory]=$functions[driver_naming_safe_directory]
driver_naming_safe_directory() { [[ -d "$1" && ! -L "$1" ]]; }
/bin/mkdir -p "$WORK/duplicate/Library/Audio/Plug-Ins/HAL"
check_driver_naming_duplicates "$WORK/duplicate" "$WORK/duplicate/Library/Audio/Plug-Ins/HAL/MiRemoteV2ch.driver"
/usr/bin/ditto "$RELEASE_OUTPUT_DIR/legacy/MiRemoteV2ch.driver" "$WORK/duplicate/Library/Audio/Plug-Ins/HAL/Copy.driver"
if check_driver_naming_duplicates "$WORK/duplicate" "$WORK/duplicate/Library/Audio/Plug-Ins/HAL/MiRemoteV2ch.driver"; then exit 1; fi
functions[driver_naming_safe_directory]=$functions[fixture_original_safe_directory]
# Execute the shipped preservation/replacement/rollback block on a fake volume.
# Only chown is stubbed: no administrator rights or system installation.
python3 - "$ROOT" "$RELEASE_OUTPUT_DIR" "$WORK" "$RELEASE_ARCH" <<'PY'
import hashlib, pathlib, plistlib, subprocess, sys
root, output, work = map(pathlib.Path, sys.argv[1:4]); arch = sys.argv[4]
source = (root/'packaging/doubao-driver/install/postinstall').read_text()
health = source[source.index('driver_architecture() {'):source.index('test -f "$RELEASE_CONFIG"')]
block = source[source.index('restore_previous_driver() {'):source.index('STAGED_DRIVER_TRASH_ROOT=')]
block = block.replace('/usr/sbin/chown', 'fixture_chown')
for scenario in ['preserve', 'repair', 'wrong_variant', 'bad_signature', 'permission_failure', 'state_failure', 'fresh', 'brand_restore']:
    volume = work/scenario; destination = volume/'Library/Audio/Plug-Ins/HAL/MiRemoteV2ch.driver'
    variant = 'brand' if scenario == 'brand_restore' else 'legacy'
    driver = output/('' if variant == 'brand' else 'legacy')/'MiRemoteV2ch.driver'
    if scenario not in ['fresh', 'brand_restore']:
        destination.parent.mkdir(parents=True)
        subprocess.run(['ditto', str(driver), str(destination)], check=True)
        if scenario != 'preserve':
            subprocess.run(['plutil','-replace','CFBundleVersion','-string','0',str(destination/'Contents/Info.plist')], check=True)
        before = hashlib.sha256((destination/'Contents/MacOS/MiRemoteV2ch').read_bytes()).hexdigest()
        before_plist = (destination/'Contents/Info.plist').read_bytes()
        before_inode = destination.stat().st_ino
    staged = volume/'staged/MiRemoteV2ch.driver'
    subprocess.run(['ditto', str(output/'MiRemoteV2ch.driver' if scenario == 'wrong_variant' else driver), str(staged)], check=True)
    if scenario == 'bad_signature':
        with (staged/'Contents/MacOS/MiRemoteV2ch').open('ab') as stream: stream.write(b'tampered')
    script = volume/'run.zsh'
    # zsh positional arguments avoid shell interpolation of local paths.
    script.write_text('''#!/bin/zsh
set -euo pipefail
source "$1/packaging/doubao-driver/install/driver-naming.zsh"
TARGET_VOLUME="$2"
DESTINATION="$2/Library/Audio/Plug-Ins/HAL/MiRemoteV2ch.driver"
PLIST="$DESTINATION/Contents/Info.plist"
BINARY="$DESTINATION/Contents/MacOS/MiRemoteV2ch"
STAGED_DRIVER="$2/staged/MiRemoteV2ch.driver"
STAGED_PLIST="$STAGED_DRIVER/Contents/Info.plist"
EXPECTED_ARCHITECTURE="$3"
SELECTED_NAMING="$5"
DRIVER_DISPLAY_NAME="$5"
DRIVER_CHANGED=0
DRIVER_BACKUP=""
SCENARIO="$4"
installer_message() { print -r -- "$2"; }
fixture_chown() { [[ "$SCENARIO" != permission_failure ]]; }
commit_driver_naming_record() { [[ "$SCENARIO" != state_failure ]]; }
''' + health + block)
    result = subprocess.run(['/bin/zsh',str(script),str(root),str(volume),arch,scenario,variant], capture_output=True, text=True)
    (volume/'result.log').write_text(result.stdout + result.stderr)
    failed = scenario in ['wrong_variant','bad_signature','permission_failure','state_failure']
    assert (result.returncode != 0) == failed, (scenario, result.stdout, result.stderr)
    if failed or scenario == 'preserve':
        assert hashlib.sha256((destination/'Contents/MacOS/MiRemoteV2ch').read_bytes()).hexdigest() == before
        assert (destination/'Contents/Info.plist').read_bytes() == before_plist
    if scenario == 'preserve':
        assert destination.stat().st_ino == before_inode, result.stdout
        assert 'changed=0' in result.stdout and 'command not found' not in result.stderr
        assert not (volume/'var/root/.Trash').exists()
    if not failed:
        subprocess.run(['codesign','--verify','--deep','--strict',str(destination)], check=True)
    print('scenario='+scenario+(' protection=verified install=failed' if failed else ' install=passed'))
# Run the complete preinstall, payload residue, failing postinstall checks and
# a new Installer attempt. Keep real marker IO, mode checks and classification;
# emulate only root ownership, hardware selection, receipts and process stop.
helper = (root/'packaging/doubao-driver/install/driver-naming.zsh').read_text()
helper = helper.replace('/usr/bin/stat', 'fixture_stat').replace('/usr/sbin/pkgutil', 'fixture_pkgutil')
stubs = '''fixture_stat() {
 if [[ "$1" == -f && "$2" == %u ]]; then print 0; else /usr/bin/stat "$@"; fi
}
fixture_pkgutil() { [[ -f "$TARGET_VOLUME/fixture-receipt" ]]; }
fixture_pkill() { return 0; }
fixture_chown() { return 0; }
fixture_sysctl() { [[ "$FIXTURE_ARCH" == arm64 ]] && print 1 || print 0; }
'''
pre = (root/'packaging/doubao-driver/install/preinstall').read_text()
pre = pre.replace('/usr/bin/pkill', 'fixture_pkill').replace('/usr/sbin/sysctl', 'fixture_sysctl')
post = source[:source.index('test -f "$LEGACY_APP_TRASH_HELPER"')]
post = post.replace('/usr/bin/stat', 'fixture_stat')
post += '\nEXPECTED_ARCHITECTURE="$FIXTURE_ARCH"\nDRIVER_CHANGED=0\nDRIVER_BACKUP=""\n' + health + block
for scenario in ['fresh_retry', 'history_retry', 'legacy_driver_retry', 'record_failure', 'invalid_record']:
    volume = work/('pkg-'+scenario)
    (volume/'Library/Application Support').mkdir(parents=True)
    destination = volume/'Library/Audio/Plug-Ins/HAL/MiRemoteV2ch.driver'
    naming = volume/'Library/Application Support/RemoteMic/DriverNaming'
    expected = 'legacy' if scenario == 'legacy_driver_retry' else 'brand'
    if scenario == 'history_retry': (volume/'fixture-receipt').write_text('owned-product-receipt')
    if scenario == 'legacy_driver_retry':
        subprocess.run(['ditto',str(output/'legacy/MiRemoteV2ch.driver'),str(destination)],check=True)
        original = (destination/'Contents/MacOS/MiRemoteV2ch').read_bytes()
        original_inode = destination.stat().st_ino
    if scenario in ['record_failure','invalid_record']:
        naming.mkdir(parents=True)
        if scenario == 'record_failure': naming.chmod(0o555)
        else:
            (naming/'brand').write_text('invalid')
            (naming/'brand').chmod(0o600)
    for attempt in [1,2]:
        scripts = volume/f'scripts-{attempt}'; scripts.mkdir()
        (scripts/'driver-naming.zsh').write_text(f'FIXTURE_ARCH={arch}\n' + stubs + helper)
        (scripts/'preinstall').write_text(pre)
        (scripts/'postinstall').write_text(post)
        (scripts/'release-variant.plist').write_bytes(plistlib.dumps({
            'ExpectedArchitecture':arch,'MinimumSystemMajor':13,'PackageBuild':'999999'}))
        result = subprocess.run(['/bin/zsh',str(scripts/'preinstall'),'fixture','fixture',str(volume)],capture_output=True,text=True)
        (scripts/'preinstall.log').write_text(result.stdout + result.stderr)
        if scenario in ['record_failure','invalid_record']:
            reason = 'state_commit_failed' if scenario == 'record_failure' else 'invalid_state'
            assert result.returncode != 0 and f'reason={reason}' in result.stderr, (scenario,result.stdout,result.stderr)
            assert not (volume/'Applications').exists() and not destination.exists()
            assert 'Stopped the running' not in result.stdout
            break
        assert result.returncode == 0, (scenario,result.stdout,result.stderr)
        assert plistlib.loads((scripts/'driver-naming-selection.plist').read_bytes())['Variant'] == expected, result.stdout
        assert (naming/expected).read_text().strip() == f'SayAllDriverNaming:1:{expected}'
        assert (naming/expected).stat().st_mode & 0o777 == 0o600
        app = volume/'Applications/SayAll.app/Contents'; app.mkdir(parents=True,exist_ok=True)
        (app/'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'com.hd838a.RemoteMic','CFBundleVersion':'999999'}))
        (volume/'fixture-receipt').write_text('owned-product-receipt')
        staging = volume/'Library/Application Support/RemoteMic/Installer'
        for variant in ['brand','legacy']:
            suffix = '' if variant == 'brand' else 'legacy'
            subprocess.run(['ditto',str(output/suffix/'MiRemoteV2ch.driver'),str(staging/suffix/'MiRemoteV2ch.driver')],check=True)
        if attempt == 1:
            staged = staging/('' if expected == 'brand' else 'legacy')/'MiRemoteV2ch.driver/Contents/MacOS/MiRemoteV2ch'
            with staged.open('ab') as stream: stream.write(b'tampered')
        result = subprocess.run(['/bin/zsh',str(scripts/'postinstall'),'fixture','fixture',str(volume)],capture_output=True,text=True)
        (scripts/'postinstall.log').write_text(result.stdout + result.stderr)
        if attempt == 1:
            assert result.returncode != 0 and 'reason=invalid_payload' in result.stderr, (scenario,result.stdout,result.stderr)
            if scenario == 'legacy_driver_retry':
                assert (destination/'Contents/MacOS/MiRemoteV2ch').read_bytes() == original
            else: assert not destination.exists()
        else:
            assert result.returncode == 0 and f'variant={expected}' in result.stdout, (scenario,result.stdout,result.stderr)
            if scenario == 'legacy_driver_retry':
                assert destination.stat().st_ino == original_inode and 'changed=0' in result.stdout
    print('pkg_scenario='+scenario+(' protection=verified install=failed' if scenario in ['record_failure','invalid_record'] else ' driver_install=passed retry=passed'))
# Recovery acceptance executes the complete shipped pre/post scripts, including
# final App permissions/signature verification and the completion message.
# This isolated volume cannot prove native Installer UI or CoreAudio loading.
full_post = source.replace('/usr/bin/stat', 'fixture_stat').replace('/usr/sbin/sysctl', 'fixture_sysctl')
full_post = full_post.replace('/usr/sbin/chown', 'fixture_chown').replace('/usr/bin/pgrep', 'fixture_pgrep')
full_post = full_post.replace('/usr/bin/killall', 'fixture_killall')
full_stubs = stubs.replace('then print 0;', 'then print 0;') + '''fixture_pgrep() { return 1; }
fixture_killall() { return 1; }
'''
# Console identity is fixed to root so no real user's home is queried.
full_stubs = full_stubs.replace('if [[ "$1" == -f && "$2" == %u ]];',
    'if [[ "$1" == -f && "$2" == %Su ]]; then print root; return 0; fi\n if [[ "$1" == -f && "$2" == %u ]];')
fixture_executable = work/'fixture-app-executable'
subprocess.run(['xcrun','clang','-arch',arch,'-x','c','-o',str(fixture_executable),'-'],input='int main(void) { return 0; }',text=True,check=True)
for scenario in ['legacy_stale_brand', 'brand_stale_legacy', 'legacy_two_records', 'brand_two_records',
                 'legacy_no_exec', 'brand_no_exec', 'legacy_bad_signature', 'brand_bad_signature',
                 'legacy_unreadable_binary', 'brand_missing_marker', 'legacy_record_write_retry', 'brand_record_write_retry', 'legacy_unreadable_two_records', 'legacy_missing_driver_two_records']:
    volume = work/('recovery-'+scenario)
    (volume/'Library/Application Support').mkdir(parents=True)
    destination = volume/'Library/Audio/Plug-Ins/HAL/MiRemoteV2ch.driver'
    expected = scenario.split('_')[0]
    driver = output/('' if expected == 'brand' else 'legacy')/'MiRemoteV2ch.driver'
    if 'missing_driver' not in scenario:
        subprocess.run(['ditto',str(driver),str(destination)],check=True)
    binary = destination/'Contents/MacOS/MiRemoteV2ch'
    if scenario.endswith('no_exec'): binary.chmod(0o644)
    if scenario.endswith('bad_signature'):
        with binary.open('ab') as stream: stream.write(b'tampered')
    if 'unreadable' in scenario: binary.write_bytes(b'damaged')
    if scenario.endswith('missing_marker'):
        subprocess.run(['plutil','-remove','SayAllNamingVariant',str(destination/'Contents/Info.plist')],check=True)
    before_binary = binary.read_bytes() if binary.exists() else None
    naming = volume/'Library/Application Support/RemoteMic/DriverNaming'; naming.mkdir(parents=True)
    old_records = {}
    if 'stale' in scenario or 'two_records' in scenario or 'record_write_retry' in scenario:
        variants = ['brand','legacy'] if 'two_records' in scenario else ['brand' if expected == 'legacy' else 'legacy']
        for variant in variants:
            marker = naming/variant; marker.write_text(f'SayAllDriverNaming:1:{variant}\n'); marker.chmod(0o600)
            old_records[variant] = marker.read_bytes()
    if 'missing_driver' in scenario: expected = 'brand'
    settings = volume/'Users/fixture/Library/Preferences/com.hd838a.RemoteMic.plist'
    settings.parent.mkdir(parents=True)
    settings.write_bytes(plistlib.dumps({'selectedAudioDeviceUID':'MiRemoteV2ch_UID','fixtureSetting':'preserve'}))
    before_settings = settings.read_bytes()
    scripts = volume/'scripts'; scripts.mkdir()
    (scripts/'driver-naming.zsh').write_text(f'FIXTURE_ARCH={arch}\n' + full_stubs + helper)
    (scripts/'preinstall').write_text(pre)
    (scripts/'postinstall').write_text(full_post)
    (scripts/'trash-legacy-app.zsh').write_bytes((root/'packaging/doubao-driver/install/trash-legacy-app.zsh').read_bytes())
    (scripts/'release-variant.plist').write_bytes(plistlib.dumps({
        'ExpectedArchitecture':arch,'MinimumSystemMajor':13,'MinimumSystemVersion':'13.0','PackageBuild':'999999'}))
    if scenario.endswith('record_write_retry'):
        real_helper = (scripts/'driver-naming.zsh').read_text()
        # Emulate a failed marker write after file creation. The next real
        # attempt must restore/reconcile the record and complete installation.
        failing_helper = real_helper.replace('print -r -- "SayAllDriverNaming:1:$variant" >',
            'false >')
        (scripts/'driver-naming.zsh').write_text(failing_helper)
        failed_result = subprocess.run(['/bin/zsh',str(scripts/'preinstall'),'fixture','fixture',str(volume)],capture_output=True,text=True)
        (scripts/'failed-preinstall.log').write_text(failed_result.stdout+failed_result.stderr)
        assert failed_result.returncode != 0 and 'reason=state_commit_failed' in failed_result.stderr
        assert binary.read_bytes() == before_binary and settings.read_bytes() == before_settings
        assert {p.name:p.read_bytes() for p in naming.iterdir()} == old_records
        assert not (volume/'Applications').exists()
        (scripts/'driver-naming.zsh').write_text(real_helper)
        retry = volume/'successful-scripts'; retry.mkdir()
        for name in ['driver-naming.zsh','preinstall','postinstall','trash-legacy-app.zsh','release-variant.plist']:
            (retry/name).write_bytes((scripts/name).read_bytes())
        scripts = retry
    result = subprocess.run(['/bin/zsh',str(scripts/'preinstall'),'fixture','fixture',str(volume)],capture_output=True,text=True)
    (scripts/'preinstall.log').write_text(result.stdout+result.stderr)
    assert result.returncode == 0,(scenario,result.stdout,result.stderr)
    assert plistlib.loads((scripts/'driver-naming-selection.plist').read_bytes())['Variant'] == expected
    assert list(p.name for p in naming.iterdir()) == [expected]
    trash = volume/'private/var/root/.Trash'
    if old_records:
        backups = list(trash.glob('SayAllDriverNaming-*'))
        assert all(p.read_bytes() in old_records.values() for p in backups if '-failed-' not in p.name)
        assert all(any(p.read_bytes() == contents for p in backups) for contents in old_records.values())
        assert 'phase=reconciled result=verified' in result.stderr
    app = volume/'Applications/SayAll.app/Contents'; app.mkdir(parents=True)
    (app/'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'com.hd838a.RemoteMic',
        'CFBundleExecutable':'RemoteMic','CFBundleVersion':'999999','LSMinimumSystemVersion':'13.0'}))
    # Small signed fixture App; no real App or user process is run by these tests.
    executables = ['MacOS/RemoteMic','Helpers/SayAllMCP','Helpers/SayAllAppleRemoteAudioCapture',
        'Helpers/SayAllAppleRemoteHCIService','Frameworks/Sparkle.framework/Versions/B/Sparkle',
        'Frameworks/Sparkle.framework/Versions/B/Autoupdate',
        'Frameworks/Sparkle.framework/Versions/B/Updater.app/Contents/MacOS/Updater',
        'Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer',
        'Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader']
    for executable in executables:
        target = app/executable; target.parent.mkdir(parents=True,exist_ok=True)
        target.write_bytes(fixture_executable.read_bytes()); target.chmod(0o755)
    for relative, executable in [('Updater.app','Updater'),('XPCServices/Installer.xpc','Installer'),('XPCServices/Downloader.xpc','Downloader')]:
        info = app/'Frameworks/Sparkle.framework/Versions/B'/relative/'Contents/Info.plist'
        info.write_bytes(plistlib.dumps({'CFBundleIdentifier':'test.'+executable,'CFBundleExecutable':executable,'CFBundlePackageType':'APPL' if executable == 'Updater' else 'XPC!'}))
    framework = app/'Frameworks/Sparkle.framework'
    resources = framework/'Versions/B/Resources'; resources.mkdir()
    (resources/'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'test.Sparkle',
        'CFBundleExecutable':'Sparkle','CFBundlePackageType':'FMWK'}))
    (framework/'Versions/Current').symlink_to('B')
    (framework/'Resources').symlink_to('Versions/Current/Resources')
    (framework/'Sparkle').symlink_to('Versions/Current/Sparkle')
    subprocess.run(['codesign','--force','--deep','--sign','-','--timestamp=none',str(app.parent)],check=True)
    staging = volume/'Library/Application Support/RemoteMic/Installer'
    for variant in ['brand','legacy']:
        suffix = '' if variant == 'brand' else 'legacy'
        subprocess.run(['ditto',str(output/suffix/'MiRemoteV2ch.driver'),str(staging/suffix/'MiRemoteV2ch.driver')],check=True)
    for attempt in [1,2]:
        if attempt == 2:
            retry = volume/'retry-scripts'; retry.mkdir()
            for name in ['driver-naming.zsh','preinstall','postinstall','trash-legacy-app.zsh','release-variant.plist']:
                (retry/name).write_bytes((scripts/name).read_bytes())
            scripts = retry
            result = subprocess.run(['/bin/zsh',str(scripts/'preinstall'),'fixture','fixture',str(volume)],capture_output=True,text=True)
            assert result.returncode == 0,(scenario,result.stdout,result.stderr)
            for variant in ['brand','legacy']:
                suffix = '' if variant == 'brand' else 'legacy'
                subprocess.run(['ditto',str(output/suffix/'MiRemoteV2ch.driver'),str(staging/suffix/'MiRemoteV2ch.driver')],check=True)
        result = subprocess.run(['/bin/zsh',str(scripts/'postinstall'),'fixture','fixture',str(volume)],capture_output=True,text=True)
        (scripts/'postinstall.log').write_text(result.stdout+result.stderr)
        assert result.returncode == 0 and 'Installation is complete.' in result.stdout,(scenario,result.stdout,result.stderr)
        assert f'phase=installed result=verified variant={expected}' in result.stdout
        subprocess.run(['codesign','--verify','--deep','--strict',str(destination)],check=True)
        subprocess.run(['codesign','--verify','--deep','--strict',str(app.parent)],check=True)
        assert settings.read_bytes() == before_settings
        assert (naming/expected).read_text().strip() == f'SayAllDriverNaming:1:{expected}'
        assert (naming/expected).stat().st_mode & 0o777 == 0o600
        if attempt == 2: assert 'changed=0' in result.stdout
    if scenario.endswith(('no_exec','bad_signature','unreadable_binary','unreadable_two_records','missing_marker')):
        backups = list((volume/'var/root/.Trash').glob('*.driver'))
        assert len(backups) == 1 and (backups[0]/'Contents/MacOS/MiRemoteV2ch').read_bytes() == before_binary
    print('recovery_scenario='+scenario+' install=passed retry=passed settings=preserved')
# Execute production uninstall/preinstall/postinstall on isolated volumes.
# These fixtures never start an App, access a real user home or modify system HAL.
uninstall = (root/'packaging/doubao-driver/uninstall/postinstall').read_text()
uninstall = uninstall.replace('/usr/bin/stat', 'fixture_stat').replace('/usr/sbin/chown', 'fixture_chown')
uninstall = uninstall.replace('/bin/mv', 'fixture_mv')
uninstall_stubs = full_stubs + '\n' + r'''fixture_mv() {
 if [[ -f "$TARGET_VOLUME/fixture-move-failure" && "$3" == "$NAMING_DIRECTORY" ]]; then return 1; fi
 /bin/mv "$@"
}
'''
for scenario in ['legacy_uninstall', 'brand_uninstall', 'conflict_uninstall', 'names_only',
                 'empty_state', 'move_retry', 'unsafe_retry', 'symlink_retry', 'foreign_entry_retry', 'old_uninstaller_residue']:
    volume = work/('reinstall-'+scenario)
    (volume/'Library/Application Support').mkdir(parents=True)
    destination = volume/'Library/Audio/Plug-Ins/HAL/MiRemoteV2ch.driver'
    naming = volume/'Library/Application Support/RemoteMic/DriverNaming'; naming.mkdir(parents=True)
    variant = 'brand' if scenario == 'brand_uninstall' else 'legacy'
    variants = ['brand','legacy'] if scenario == 'conflict_uninstall' else [variant]
    if scenario == 'empty_state': variants = []
    for name in variants:
        marker = naming/name; marker.write_text(f'SayAllDriverNaming:1:{name}\n'); marker.chmod(0o600)
    records = {p.name:p.read_bytes() for p in naming.iterdir()}
    settings = volume/'Users/fixture/Library/Preferences/com.hd838a.RemoteMic.plist'
    settings.parent.mkdir(parents=True)
    settings.write_bytes(plistlib.dumps({'selectedAudioDeviceUID':'MiRemoteV2ch_UID','fixtureSetting':'preserve'}))
    before_settings = settings.read_bytes()
    (volume/'fixture-receipt').write_text('owned-product-receipt')
    app = volume/'Applications/SayAll.app'
    has_driver = scenario not in ['names_only','empty_state','old_uninstaller_residue']
    if has_driver:
        subprocess.run(['ditto',str(output/('' if variant == 'brand' else 'legacy')/'MiRemoteV2ch.driver'),str(destination)],check=True)
        before_binary = (destination/'Contents/MacOS/MiRemoteV2ch').read_bytes()
        subprocess.run(['ditto',str(work/'recovery-legacy_stale_brand/Applications/SayAll.app'),str(app)],check=True)
    scripts = volume/'scripts'; scripts.mkdir()
    (scripts/'driver-naming.zsh').write_text(f'FIXTURE_ARCH={arch}\n'+uninstall_stubs+helper)
    (scripts/'uninstall').write_text(uninstall)
    def run_uninstall(label):
        result = subprocess.run(['/bin/zsh',str(scripts/'uninstall'),'fixture','fixture',str(volume)],capture_output=True,text=True)
        (scripts/(label+'.log')).write_text(result.stdout+result.stderr)
        return result
    if scenario in ['move_retry','unsafe_retry','symlink_retry','foreign_entry_retry']:
        if scenario == 'move_retry': (volume/'fixture-move-failure').write_text('injected')
        elif scenario == 'unsafe_retry': (naming/'legacy').chmod(0o666)
        elif scenario == 'symlink_retry':
            (naming/'legacy').rename(volume/'original-marker')
            (naming/'legacy').symlink_to(volume/'original-marker')
        else: (naming/'foreign').write_text('unowned')
        failed = run_uninstall('failed-uninstall')
        assert failed.returncode != 0,(scenario,failed.stdout,failed.stderr)
        reason = 'move_failed' if scenario == 'move_retry' else 'invalid_state'
        assert f'reason={reason}' in failed.stderr
        assert app.exists() and destination.exists() and naming.exists()
        assert (destination/'Contents/MacOS/MiRemoteV2ch').read_bytes() == before_binary
        assert settings.read_bytes() == before_settings
        if scenario == 'move_retry':
            assert {p.name:p.read_bytes() for p in naming.iterdir()} == records
            (volume/'fixture-move-failure').rename(volume/'resolved-move-failure')
        elif scenario == 'unsafe_retry': (naming/'legacy').chmod(0o600)
        elif scenario == 'symlink_retry':
            (naming/'legacy').rename(volume/'rejected-symlink')
            (volume/'original-marker').rename(naming/'legacy')
        else: (naming/'foreign').rename(volume/'preserved-foreign')
    if scenario != 'old_uninstaller_residue':
        result = run_uninstall('uninstall')
        assert result.returncode == 0,(scenario,result.stdout,result.stderr)
        assert 'phase=uninstall_completed result=verified records=trashed' in result.stdout
        assert not naming.exists() and not destination.exists() and not app.exists()
        backups = list((volume/'.Trashes/0').glob('SayAllDriverNaming*.state'))
        assert len(backups) == 1
        assert {p.name:p.read_bytes() for p in backups[0].iterdir()} == records
    # The old 1.9.21 uninstaller leaves records/receipts/preferences with no HAL
    # driver. Reproduce that final state without an external/network fixture.
    assert settings.read_bytes() == before_settings
    assert (volume/'fixture-receipt').read_text() == 'owned-product-receipt'
    for attempt in [1,2]:
        install_scripts = volume/f'install-scripts-{attempt}'; install_scripts.mkdir()
        (install_scripts/'driver-naming.zsh').write_text(f'FIXTURE_ARCH={arch}\n'+full_stubs+helper)
        (install_scripts/'preinstall').write_text(pre)
        (install_scripts/'postinstall').write_text(full_post)
        (install_scripts/'trash-legacy-app.zsh').write_bytes((root/'packaging/doubao-driver/install/trash-legacy-app.zsh').read_bytes())
        (install_scripts/'release-variant.plist').write_bytes(plistlib.dumps({
            'ExpectedArchitecture':arch,'MinimumSystemMajor':13,'MinimumSystemVersion':'13.0','PackageBuild':'999999'}))
        result = subprocess.run(['/bin/zsh',str(install_scripts/'preinstall'),'fixture','fixture',str(volume)],capture_output=True,text=True)
        (install_scripts/'preinstall.log').write_text(result.stdout+result.stderr)
        assert result.returncode == 0,(scenario,result.stdout,result.stderr)
        assert plistlib.loads((install_scripts/'driver-naming-selection.plist').read_bytes())['Variant'] == 'brand'
        subprocess.run(['ditto',str(work/'recovery-legacy_stale_brand/Applications/SayAll.app'),str(app)],check=True)
        staging = volume/'Library/Application Support/RemoteMic/Installer'
        for name in ['brand','legacy']:
            suffix = '' if name == 'brand' else 'legacy'
            subprocess.run(['ditto',str(output/suffix/'MiRemoteV2ch.driver'),str(staging/suffix/'MiRemoteV2ch.driver')],check=True)
        result = subprocess.run(['/bin/zsh',str(install_scripts/'postinstall'),'fixture','fixture',str(volume)],capture_output=True,text=True)
        (install_scripts/'postinstall.log').write_text(result.stdout+result.stderr)
        assert result.returncode == 0 and 'Installation is complete.' in result.stdout,(scenario,result.stdout,result.stderr)
        assert 'phase=installed result=verified variant=brand' in result.stdout
        if attempt == 2: assert 'changed=0' in result.stdout
        subprocess.run(['codesign','--verify','--deep','--strict',str(destination)],check=True)
        assert (destination/'Contents/MacOS/MiRemoteV2ch').read_bytes() == (output/'MiRemoteV2ch.driver/Contents/MacOS/MiRemoteV2ch').read_bytes()
        assert len(list(destination.parent.glob('*.driver'))) == 1
        assert list(p.name for p in naming.iterdir()) == ['brand']
        assert settings.read_bytes() == before_settings
    print('reinstall_scenario='+scenario+' uninstall=passed install=passed retry=passed settings=preserved'
        if scenario != 'old_uninstaller_residue' else 'reinstall_scenario='+scenario+' install=passed retry=passed settings=preserved')
# The developer entry point must use the same resolver and preserve restoration.
direct = (root/'scripts/install-doubao-driver.sh').read_text()
direct = direct[direct.index('installer_message() {'):direct.index('# The driver is already in place;')]
for scenario in ['fresh', 'history', 'brand_record', 'legacy_record', 'state_failure', 'existing']:
    volume = work/('direct-'+scenario); volume.mkdir()
    destination = volume/'HAL/MiRemoteV2ch.driver'; destination.parent.mkdir()
    if scenario == 'existing':
        subprocess.run(['ditto',str(output/'legacy/MiRemoteV2ch.driver'),str(destination)],check=True)
        before = (destination/'Contents/MacOS/MiRemoteV2ch').read_bytes()
    script = volume/'run.zsh'
    script.write_text('''#!/bin/zsh
set -euo pipefail
ROOT="$1"
DESTINATION="$2/HAL/MiRemoteV2ch.driver"
SCENARIO="$3"
source "$ROOT/packaging/doubao-driver/install/driver-naming.zsh"
prepare_driver_naming_directory() { NAMING_DIRECTORY="${DESTINATION:h}/Naming"; }
check_driver_naming_duplicates() { return 0; }
driver_naming_record() {
 case "$SCENARIO" in brand_record) print brand;; legacy_record) print legacy;; *) print none;; esac
}
has_driver_naming_history() { [[ "$SCENARIO" == history ]]; }
commit_driver_naming_record() { [[ "$SCENARIO" != state_failure ]]; }
driver_naming_safe_directory() { [[ -d "$1" && ! -L "$1" ]]; }
chown() { return 0; }
''' + direct.replace('/Applications/',str(volume/'Applications')+'/')
        .replace('/var/root/.Trash',str(volume/'Trash'))
        .replace('$ROOT/dist',str(output)))
    result = subprocess.run(['/bin/zsh',str(script),str(root),str(volume),scenario],capture_output=True,text=True)
    failed = scenario in ['state_failure','existing']
    assert (result.returncode != 0) == failed,(scenario,result.stdout,result.stderr)
    if scenario == 'existing':
        assert (destination/'Contents/MacOS/MiRemoteV2ch').read_bytes()==before
    elif scenario == 'state_failure':
        assert not destination.exists()
        assert len(list((volume/'Trash').glob('*.driver')))==1
    else:
        expected='brand'
        result = subprocess.run(['/bin/zsh','-c','source "$1"; driver_naming_variant "$2"','fixture',str(root/'packaging/doubao-driver/install/driver-naming.zsh'),str(destination)],capture_output=True,text=True,check=True)
        assert result.stdout.strip()==expected,(scenario,result.stdout)
    print('direct_scenario='+scenario+' result=passed')

PY
print "DRIVER NAMING FIXTURES PASS (retained): $WORK"
