#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
script_name="${0:t}"

usage() {
  print -u2 "usage: $script_name [LOCALIZATION_DIRECTORY ...]"
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if (( $# > 0 )); then
  LOCALIZATION_DIRS=("$@")
else
  LOCALIZATION_DIRS=("$ROOT"/Resources/*.lproj(N))
fi

if (( ${#LOCALIZATION_DIRS} == 0 )); then
  print -u2 "no localization directories to verify"
  exit 1
fi

for directory in "${LOCALIZATION_DIRS[@]}"; do
  test -d "$directory" || { print -u2 "localization directory is missing: $directory"; exit 1; }
  test -f "$directory/InfoPlist.strings" || { print -u2 "missing InfoPlist.strings: $directory"; exit 1; }
  test -f "$directory/Localizable.strings" || { print -u2 "missing Localizable.strings: $directory"; exit 1; }
  plutil -lint "$directory/InfoPlist.strings"
  plutil -lint "$directory/Localizable.strings"
done

# The packaged App and the source tree share this check so a key that a release
# gate rejects cannot reach CI green and only fail once a signed build exists.
/usr/bin/ruby - "${LOCALIZATION_DIRS[@]}" <<'RUBY'
def strings(path)
  result = {}
  File.foreach(path, encoding: "UTF-8") do |line|
    match = line.match(/^"([^"]+)" = "(.*)";$/)
    result[match[1]] = match[2] if match
  end
  result
end

directories = ARGV
english_directory = directories.find { |path| File.basename(path) == "en.lproj" }
abort "English localization is required" unless english_directory
english = strings(File.join(english_directory, "Localizable.strings"))
abort "English localization is empty" if english.empty?
semantic_key = /\A[a-z0-9]+(?:[._][a-z0-9]+)*\z/
invalid_keys = english.keys.reject { |key| semantic_key.match?(key) }
abort "Invalid localization keys: #{invalid_keys.join(", ")}" unless invalid_keys.empty?

format_pattern = /%(?:[0-9]+\$)?[a-zA-Z@]/
restricted_terms = /RC003|ATVV|\bHID\b|\bUUID\b|virtual[ -]transport/i
# Keys whose copy is intentionally empty in some languages, because the UI omits
# the whole label instead of translating it. Keep in sync with the same list in
# Tests/RemoteMicTests/LocalizationTests.swift; every other empty value still fails.
intentionally_empty_keys = ["statistics.metric.count_unit"]
directories.each do |directory|
  localized = strings(File.join(directory, "Localizable.strings"))
  missing = english.keys - localized.keys
  extra = localized.keys - english.keys
  abort "#{directory} has missing keys: #{missing.join(", ")}" unless missing.empty?
  abort "#{directory} has extra keys: #{extra.join(", ")}" unless extra.empty?
  localized.each do |key, value|
    if value.empty?
      abort "#{directory} has an empty value for #{key}" unless intentionally_empty_keys.include?(key)
      next
    end
    expected_formats = english.fetch(key).scan(format_pattern).sort
    actual_formats = value.scan(format_pattern).sort
    abort "#{directory} has mismatched formats for #{key}" unless actual_formats == expected_formats
    abort "#{directory} exposes a restricted term in #{key}" if value.match?(restricted_terms)
  end

  english_info = strings(File.join(english_directory, "InfoPlist.strings"))
  localized_info = strings(File.join(directory, "InfoPlist.strings"))
  abort "#{directory} has incomplete InfoPlist.strings" unless localized_info.keys.sort == english_info.keys.sort
end
RUBY

print "LOCALIZATION VERIFY PASS: ${#LOCALIZATION_DIRS} directories"
