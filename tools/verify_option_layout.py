#!/usr/bin/env python3
"""Validate the built-in settings layout: categories, option pages and i18n keys.

Read-only. Fails (exit 1) when

  * any option "variable" appears twice across the built-in pages,
  * the set of built-in variables differs from BASELINE_VARIABLES,
  * a category's "optionsFile" has no page next to categories.json,
  * "language" is not the first entry of the general page,
  * a category nameKey / description key is missing in one of the languages.

BASELINE_VARIABLES is the 87 options that existed before the settings were
re-ordered; keeping it frozen here is what makes "no option was dropped or
duplicated by the reshuffle" a checkable statement instead of a claim.

NOTE_OPTIMISATION_VARIABLES pins the note-optimisation page to exactly the five
extreme-chart switches the user asked for: lowQuality, cacheOnGPU, gfxLruCache,
gfxRuntimeRepack, gfxCpuRelease, asyncImageLoading, clearImageCache,
globalAntialiasing, shaders, disableGC, separateUpdateDraw, framerate and
drawFramerate must stay on the graphics page.
"""
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OPTIONS_DIR = os.path.join(ROOT, 'assets', 'preload', 'data', 'options')
LANG_DIR = os.path.join(ROOT, 'assets', 'lang')
LANGUAGES = ['English', 'ChineseSimplified', 'ChineseTraditional']

# Options added after the reshuffle on purpose: the A5 storage-location warning
# toggle, the "show the note-optimisation notice again" action row and the
# bottom-right version watermark toggle.
EXPECTED_NEW_VARIABLES = {'showStorageRootWarning', 'showNoteOptimizationNotice', 'showWatermark'}

# The only five switches that belong to the note-optimisation page (plus action rows).
NOTE_OPTIMISATION_VARIABLES = {'perfMode', 'turboMode', 'limitNotes', 'fastSort', 'bulkSkip'}
NOTE_OPTIMISATION_ACTIONS = {'showNoteOptimizationNotice'}

BASELINE_VARIABLES = {
    # general
    'language', 'checkForUpdates', 'checkForPrereleases', 'freeplayAutoPreview', 'oldmodsmenu',
    'oldPauseMenu', 'seiuMenuFx', 'sidehud', 'opponentfe',
    # gameplay
    'controllerMode', 'downScroll', 'middleScroll', 'keyboardDisplay', 'opponentStrums',
    'ghostTapping', 'noReset', 'lastNoteAnimation', 'saveReplayData', 'trackAlpha',
    'guitarHeroSustains', 'ratingOffset', 'safeFrames', 'marvelousRatings', 'judgementPreset',
    'marvelousWindow', 'sickWindow', 'goodWindow', 'badWindow',
    # audio
    'hitsound', 'hitsoundVolume', 'pauseMusic',
    # visuals
    'noteSplashes', 'noteSkin', 'noteStyle', 'noteRGBMode', 'splashSkin', 'comboStacking',
    'scoreZoom', 'healthBarAlpha', 'timeBarType', 'hideHud', 'showFP', 'newFPPreview', 'showFPS',
    'flashing', 'camZooms',
    # graphics
    'lowQuality', 'perfMode', 'turboMode', 'globalAntialiasing', 'shaders', 'cacheOnGPU',
    'asyncImageLoading', 'gfxLruCache', 'gfxRuntimeRepack', 'gfxCpuRelease', 'clearImageCache',
    'limitNotes', 'fastSort', 'bulkSkip', 'disableGC', 'separateUpdateDraw', 'framerate',
    'drawFramerate', 'windowedmode', 'runInBackground', 'backgroundDim', 'closeAnimStyle',
    'closeAnimSpeed',
    # advanced (kept the historical id extra_settings)
    'compatEngine', 'hscriptErrorHandling', 'ignoreErrorLoopScripts', 'scriptErrorLimit', 'luattf',
    'newchartingstate', 'chartAutosave', 'traceConsoleEnabled', 'traceConsoleLevel',
    # android
    'storageType', 'autoExtractAssets', 'touchControls', 'touchSwipeEnabled', 'mobileCAlpha',
    'hitboxExtraToggle', 'hitboxExtraPos', 'hitboxPressAlpha', 'hitboxBorder',
}

EXPECTED_CATEGORY_ORDER = [
    'general', 'gameplay', 'visuals', 'graphics', 'note_optimization', 'audio',
    'controls', 'adjust', 'notecolor', 'notecolor_rgb', 'android_settings',
    'extra_settings', 'backup', 'touch_controls',
]

failures = []
notes = []


def load(path):
    with open(path, 'r', encoding='utf-8') as handle:
        return json.load(handle)


def main():
    categories = load(os.path.join(OPTIONS_DIR, 'categories.json'))

    ids = [c['id'] for c in categories]
    if ids != EXPECTED_CATEGORY_ORDER:
        failures.append('category order is %s, expected %s' % (ids, EXPECTED_CATEGORY_ORDER))

    pages = {}
    for name in sorted(os.listdir(OPTIONS_DIR)):
        if not name.endswith('.json') or name == 'categories.json':
            continue
        pages[name[:-len('.json')]] = load(os.path.join(OPTIONS_DIR, name))

    wanted = set()
    for cat in categories:
        if cat.get('type') != 'settings':
            continue
        page = cat.get('optionsFile')
        if not page:
            failures.append('category %s has no optionsFile' % cat['id'])
            continue
        wanted.add(page)
        if page not in pages:
            failures.append('category %s points at missing page %s.json' % (cat['id'], page))

    for page in pages:
        if page not in wanted:
            failures.append('page %s.json has no category' % page)

    seen = {}
    for page, entries in pages.items():
        for index, entry in enumerate(entries):
            variable = entry.get('variable')
            if not variable:
                failures.append('%s.json[%d] has no variable' % (page, index))
                continue
            if variable in seen:
                failures.append('variable %s appears in %s and %s' % (variable, seen[variable], page))
            seen[variable] = page

    found = set(seen)
    missing = BASELINE_VARIABLES - found
    added = found - BASELINE_VARIABLES
    if missing:
        failures.append('baseline variables missing after the reshuffle: %s' % sorted(missing))
    if added != EXPECTED_NEW_VARIABLES:
        failures.append('unexpected new variables: %s (expected %s)'
                        % (sorted(added), sorted(EXPECTED_NEW_VARIABLES)))

    general = [e['variable'] for e in pages.get('general', [])]
    if not general or general[0] != 'language':
        failures.append('language is not the first entry of the general page: %s' % general)

    # The note-optimisation page must hold exactly the five extreme-chart switches.
    # Action rows ("button") are allowed on top of them and are checked separately.
    note_page = pages.get('note_optimization')
    if note_page is None:
        failures.append('note_optimization.json is missing')
    else:
        note_switches = {e['variable'] for e in note_page if e.get('type') != 'button'}
        if note_switches != NOTE_OPTIMISATION_VARIABLES:
            failures.append('note_optimization page holds %s, expected exactly %s'
                            % (sorted(note_switches), sorted(NOTE_OPTIMISATION_VARIABLES)))
        for entry in note_page:
            if entry.get('type') == 'button' and entry['variable'] not in NOTE_OPTIMISATION_ACTIONS:
                failures.append('unexpected action row %s on the note_optimisation page' % entry['variable'])
        for variable in sorted(NOTE_OPTIMISATION_VARIABLES):
            owner = seen.get(variable)
            if owner is not None and owner != 'note_optimization':
                failures.append('%s must live on the note_optimization page, found in %s'
                                % (variable, owner))

    notes.append('pages: %s' % ', '.join('%s=%d' % (p, len(pages[p])) for p in sorted(pages)))
    notes.append('unique variables: %d (baseline %d + %d new)'
                 % (len(found), len(BASELINE_VARIABLES), len(added)))

    strings = {}
    for language in LANGUAGES:
        strings[language] = load(os.path.join(LANG_DIR, language, 'option.json'))

    required = set()
    for cat in categories:
        for key in ('nameKey', 'rpcTitleKey'):
            if cat.get(key):
                required.add(cat[key])
    for entries in pages.values():
        for entry in entries:
            for key in ('nameKey', 'descKey'):
                if entry.get(key):
                    required.add(entry[key])

    for language in LANGUAGES:
        absent = sorted(k for k in required if k not in strings[language])
        hard = [k for k in absent if not k.endswith('.rctitle')]
        if hard:
            failures.append('%s is missing %d key(s): %s' % (language, len(hard), hard[:10]))
        soft = [k for k in absent if k.endswith('.rctitle')]
        if soft:
            notes.append('%s: %d rpcTitleKey fall back to the default title: %s'
                         % (language, len(soft), soft))

    notes.append('option.json keys: %s'
                 % ', '.join('%s=%d' % (l, len(strings[l])) for l in LANGUAGES))

    for line in notes:
        print('note: ' + line)

    if failures:
        for line in failures:
            print('FAIL: ' + line)
        return 1

    print('OK: settings layout is consistent')
    return 0


if __name__ == '__main__':
    sys.exit(main())
