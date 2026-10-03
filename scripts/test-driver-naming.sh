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
import hashlib, pathlib, subprocess, sys
root, output, work = map(pathlib.Path, sys.argv[1:4]); arch = sys.argv[4]
source = (root/'packaging/doubao-driver/install/postinstall').read_text()
health = source[source.index('driver_is_healthy_and_current() {'):source.index('test -f "$RELEASE_CONFIG"')]
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
    failed = scenario in ['wrong_variant','bad_signature','permission_failure','state_failure']
    assert (result.returncode != 0) == failed, (scenario, result.stdout, result.stderr)
    if failed or scenario == 'preserve':
        assert hashlib.sha256((destination/'Contents/MacOS/MiRemoteV2ch').read_bytes()).hexdigest() == before
        assert (destination/'Contents/Info.plist').read_bytes() == before_plist
    else:
        subprocess.run(['codesign','--verify','--deep','--strict',str(destination)], check=True)
    print('scenario='+scenario+' result=passed')
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
        expected='legacy' if scenario in ['history','legacy_record'] else 'brand'
        result = subprocess.run(['/bin/zsh','-c','source "$1"; driver_naming_variant "$2"','fixture',str(root/'packaging/doubao-driver/install/driver-naming.zsh'),str(destination)],capture_output=True,text=True,check=True)
        assert result.stdout.strip()==expected,(scenario,result.stdout)
    print('direct_scenario='+scenario+' result=passed')

PY
print "DRIVER NAMING FIXTURES PASS (retained): $WORK"
