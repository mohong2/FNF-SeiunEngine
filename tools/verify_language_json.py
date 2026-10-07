#!/usr/bin/env python3
"""Validate every assets/lang/<Lang>/*.json language file.

Why this exists: Language.loadDirectory() wraps Json.parse in a try/catch and only
traces "Failed to load language file: <path>" on failure, so ONE syntax error (a
missing comma after an appended key, for example) silently discards the whole
file and every string in it falls back to the built-in English default -- a
shipped-build regression that no engine test would catch.

Checks, per file:
  * the file parses as JSON;
  * every value is a string (a nested object would be stored as a non-String);
  * the same file exists in every language and has exactly the same key set;
  * key ORDER matches too (Language.loadDirectory only merges into a map, so
    order is cosmetic -- reported as a warning, not an error).

Usage:  python tools/verify_language_json.py [lang_root]
Exit code 0 = all good, 1 = at least one error.
"""

import json
import os
import sys

ROOT = sys.argv[1] if len(sys.argv) > 1 else os.path.join("assets", "lang")


def main() -> int:
    if not os.path.isdir(ROOT):
        print("language root not found: " + ROOT)
        return 1

    langs = sorted(d for d in os.listdir(ROOT) if os.path.isdir(os.path.join(ROOT, d)))
    if not langs:
        print("no language directories under " + ROOT)
        return 1

    errors = 0
    warnings = 0
    per_lang = {}
    files_by_lang = {}

    for lang in langs:
        lang_dir = os.path.join(ROOT, lang)
        # A file named after the language itself (<Lang>.json) holds that language's own
        # display name / metadata, so it is language-specific by design and must not be compared
        # against the other languages' files.
        files = sorted(f for f in os.listdir(lang_dir)
                       if f.endswith(".json") and f != lang + ".json")
        files_by_lang[lang] = files
        parsed = {}
        for name in files:
            path = os.path.join(lang_dir, name)
            try:
                with open(path, "r", encoding="utf-8-sig") as handle:
                    data = json.load(handle)
            except Exception as exc:  # noqa: BLE001 - report the parser message verbatim
                print("ERROR %s/%s: %s" % (lang, name, exc))
                errors += 1
                continue
            if not isinstance(data, dict):
                print("ERROR %s/%s: top level is %s, expected an object" % (lang, name, type(data).__name__))
                errors += 1
                continue
            bad_types = [k for k, v in data.items() if not isinstance(v, str)]
            if bad_types:
                print("ERROR %s/%s: non-string values: %s" % (lang, name, ", ".join(sorted(bad_types)[:8])))
                errors += 1
            parsed[name] = data
        per_lang[lang] = parsed

    reference = langs[0]
    for lang in langs[1:]:
        if files_by_lang[lang] != files_by_lang[reference]:
            only_ref = sorted(set(files_by_lang[reference]) - set(files_by_lang[lang]))
            only_lang = sorted(set(files_by_lang[lang]) - set(files_by_lang[reference]))
            print("ERROR file set differs: %s (missing: %s, extra: %s)" % (lang, only_ref, only_lang))
            errors += 1

    for name in files_by_lang[reference]:
        ref_data = per_lang[reference].get(name)
        if ref_data is None:
            continue
        ref_keys = list(ref_data.keys())
        for lang in langs[1:]:
            data = per_lang[lang].get(name)
            if data is None:
                continue
            keys = list(data.keys())
            missing = [k for k in ref_keys if k not in data]
            extra = [k for k in keys if k not in ref_data]
            if missing or extra:
                print("ERROR %s/%s: key set differs (missing: %s, extra: %s)"
                      % (lang, name, missing[:8], extra[:8]))
                errors += 1
            elif keys != ref_keys:
                print("WARN  %s/%s: same keys, different order" % (lang, name))
                warnings += 1

        # Empty translations are almost always an oversight, never intentional.
        for lang in langs:
            data = per_lang[lang].get(name)
            if data is None:
                continue
            empty = [k for k, v in data.items() if v.strip() == ""]
            if empty:
                print("WARN  %s/%s: empty strings: %s" % (lang, name, empty[:8]))
                warnings += 1

    total_files = sum(len(v) for v in files_by_lang.values())
    print("languages: %s" % ", ".join(langs))
    print("files: %d, keys: %s"
          % (total_files, ", ".join("%s=%d" % (lang, len(per_lang[lang].get(files_by_lang[lang][0], {})))
                                     for lang in langs)))
    print("errors: %d, warnings: %d" % (errors, warnings))
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
