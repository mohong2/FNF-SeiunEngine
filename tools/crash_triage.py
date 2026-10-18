#!/usr/bin/env python3
"""
SeiunEngine crash triage -- one self-contained tool (Python 3, standard library only).

You choose the crash report and the .map file. No arguments = window UI (tkinter: native file
dialogs, mouse, click a row to pick a report). --tui = terminal UI. Switches = scripting.

WHY THE .MAP MATTERS
  A report is only exact against the .map of the build that produced it, and every 'lime build'
  overwrites export/release/windows/obj/ApplicationMain.map. Snapshot it after a build
  (--keep-map) and this tool reuses the snapshot matching the report's build fingerprint
  (exe size + PE timestamp). Symbols taken from another build's map are marked STALE.

USAGE
  python tools/crash_triage.py                       window UI (falls back to the terminal UI)
  python tools/crash_triage.py --tui                 terminal UI
  python tools/crash_triage.py --no-gui --summary    scripted, no window at all
  python tools/crash_triage.py --crash R [-m MAP]    triage one report
  python tools/crash_triage.py --all                 triage every report in the crash dir
  python tools/crash_triage.py --summary [--json]    one line per report + signature counts
  python tools/crash_triage.py --keep-map            snapshot the current build's .map
  python tools/crash_triage.py --clean [--keep N] [--prune-maps N] [--dry-run]
  python tools/crash_triage.py --help

EXIT CODES
  0  every triaged report matched the map in use
  1  at least one report came from another build (symbols marked STALE)
  2  nothing to triage, or bad input
"""

from __future__ import annotations

import argparse
import json
import locale
import os
import re
import struct
import sys
import time
from datetime import datetime

TRANSLATIONS = {
    'en': {
        'err_not_map': 'not a linker .map (no preferred load address): {v}',
        'err_map_not_found': 'map not found: {v}',
        'err_exe_not_found': 'exe not found: {v}',
        'err_report_not_found': 'report not found: {v}',
        'err_no_reports': 'no crash reports in {v}',
        'err_nothing_picked': 'nothing picked',
        'ok': 'OK', 'fail': 'FAIL', 'skip': 'SKIP', 'stale': 'STALE', 'match': 'match', 'other': 'other',
        'ready': 'ready', 'done': 'done', 'summary_done': 'summary done', 'keep_map_done': 'keep-map done', 'archive_done': 'archive done',
        
        # TUI
        'tui_title': 'SeiunEngine crash triage',
        'tui_crash_dir': '  crash dir : {v}',
        'tui_reports': '  reports   : {v}',
        'tui_current': '  current   : {v}   ({m})',
        'tui_no_current': '  current   : (SeiunEngine.exe not found)',
        'tui_map_chosen': '  map       : {v}   (chosen by you)',
        'tui_map_auto': '  map       : auto (snapshot for the report build, else the current one)',
        'menu_newest': '  1  triage the newest report',
        'menu_listed': '  2  triage a listed report (by number)',
        'menu_dialog': '  3  choose a crash report with a file dialog',
        'menu_all': '  4  triage every report',
        'menu_summary': '  5  summary table',
        'menu_keep_map': '  6  snapshot the current .map now (keep-map)',
        'menu_list_maps': '  7  list .map snapshots',
        'menu_archive': '  8  archive old reports (keep the newest 20)',
        'menu_choose_map': '  9  choose a .map file to use from now on',
        'menu_help_quit': '  h  help        q  quit',
        'tui_help_1': 'A report is only exact against the .map of the build that produced it.',
        'tui_help_2': 'Snapshot after every build (menu 6); symbols from another build are marked STALE.',
        'tui_out_of_range': '  out of range',
        'tui_no_reports_here': '  no reports here',
        'tui_nothing_picked': '  (nothing picked)',
        'tui_nothing_picked_auto': '  (nothing picked - using auto)',
        'tui_map_for_report': 'Map file for this report:',
        'tui_auto_map': '  [Enter] auto  ->  {v}   [{q}]',
        'tui_auto_map_none': '  [Enter] auto  ->  (nothing found)',
        'tui_pick_map_dialog': '  [p]           ->  pick a .map file with a file dialog',
        'tui_paste_map_path': '  [path]        ->  paste the path of a .map file',
        'tui_use_which_map': 'Use which .map from now on?',
        'tui_auto_map_back': '  [Enter] auto  ->  back to auto',
        'tui_triage_result_ok': 'RESULT: {v} report(s), all matched the map',
        'tui_triage_result_stale': 'RESULT: {a} report(s), {b} from another build (symbols are hints)',

        # GUI
        'gui_title': 'SeiunEngine Crash Triage',
        'gui_inputs': ' Inputs  (you pick both files) ',
        'gui_crash_report': 'Crash report',
        'gui_map_file': 'Map file',
        'gui_browse': 'Browse...',
        'gui_use_map': 'use this .map   (unchecked = auto: snapshot for the report build, else the current one)',
        'gui_reports': ' Reports (newest first; click = select, double-click = triage) ',
        'gui_output': ' Output (CI-style steps + report detail) ',
        'btn_triage_selected': 'Triage selected',
        'btn_triage_all': 'Triage ALL reports',
        'btn_summary': 'Summary',
        'btn_snapshot': 'Snapshot current .map',
        'btn_archive': 'Archive old reports',
        'btn_clear': 'Clear output',
        'btn_quit': 'Quit',
        'gui_cur_build': 'current build: {v}  ({m})',
        'gui_no_cur_build': 'current build: (SeiunEngine.exe not found)',
        'gui_auto_map': 'auto map: {v}   [{q}]',
        'gui_auto_map_none': 'auto map: (none found)',
        'gui_note_exe_missing': 'note: SeiunEngine.exe was not found, so build matching cannot be checked.',
        'gui_pick_report_first': 'Pick a crash report (Browse... or click a row), optionally pick a .map, then press a button.',
        'gui_choose_report_title': 'Choose a crash report',
        'gui_choose_map_title': 'Choose a linker .map',
        'gui_all_files': 'All files',
        'gui_crash_reports': 'Crash reports',
        'gui_map_files': 'Map files',

        # 列名
        'col_date': 'date', 'col_name': 'name', 'col_kind': 'kind', 'col_exception': 'exception', 'col_state': 'state', 'col_build': 'build', 'col_symbol': 'faulting function',

        # Steps
        'step_read_report': 'read report',
        'step_fingerprint': 'report build fingerprint',
        'step_select_map': 'select .map',
        'step_load_map': 'load .map',
        'step_compare': 'compare builds',
        'step_resolve_fault': 'resolve fault offset',
        'step_resolve_bt': 'resolve backtrace',
        'step_write': 'write triage file',
        'step_skip_no_stamp': 'this older report does not record it',
        'step_no_map': 'none found - use -m/--map or snapshot with --keep-map',
        'step_map_cached': 'cached ({v} functions)',
        'step_map_loaded': '{a:.1f} MB, {b} functions, {c:.1f}s',
        'step_build_exact': 'this map is the build that produced the report',
        'step_build_stale': 'report {a} vs current {b}',
        'step_build_no_cur': 'current exe not found',
        'step_fault_detail': '0x{a:X} -> {b}',
        'step_bt_detail': 'no fault offset (abort/terminate path); {a} app frame(s), first: 0x{b:X} -> {c}',
        'step_bt_skip': 'the backtrace has no SeiunEngine.exe frames',
        'step_haxe': 'this report has no fault offset (Haxe-level crash)',
        'step_posix': 'no Windows fault offset/backtrace (POSIX report? use tools/symbolize_android.py)',
        'step_no_map_loaded': 'no map loaded',
        'step_write_ok': '{v}',
        'step_write_skip': 'disabled (--no-write)',
        'step_quality_chosen_exact': 'chosen by you (matches the report build)',
        'step_quality_chosen_hint': 'chosen by you (cannot verify against this report)',
        'step_quality_snapshot': 'snapshot for this build',
        'step_quality_current': 'current build',
        'step_quality_current_nostamp': 'current build (report has no build stamp)',
        'step_quality_current_mismatch': 'current build (MISMATCH - this report is from another build)',

        # Report Block
        'rep_app': '  app          : {v}',
        'rep_engine': '  engine       : {v}',
        'rep_exception': '  exception    : {v}{n}',
        'rep_context': '  context      : {v}',
        'rep_fault_module': '  fault module : {v}',
        'rep_error': '  error        : {v}',
        'rep_build': '  report build : {v}',
        'rep_no_build': '(not recorded in this older report)',
        'rep_cur_exe': '  current exe  : {v}',
        'rep_not_built': '(not built)',
        'rep_match_yes': '  build match  : YES - this map is the build that produced the report',
        'rep_match_no': '  build match  : NO - the map is from another build; symbols below are hints only',
        'rep_map': '  map          : {v}',
        'rep_no_map': '(none found)',
        'rep_fault_offset': '  fault offset : 0x{v:X}',
        'rep_fault_hit': '        -> {v}',
        'rep_call_stack': '  call stack (app module, first {v}):',
        'rep_stack_line': '      #{a:02d} 0x{b:X} -> {c}',
        'rep_no_fault_abort': '  fault offset : (none - abort()/terminate() path, no faulting instruction)',
        'rep_no_fault_haxe': '  fault offset : (this report has no fault offset - Haxe-level crash, nothing to symbolise)',
        'rep_no_fault_posix': '  fault offset : (native report without a Windows fault offset/backtrace - use tools/symbolize_android.py for POSIX dumps)',

        # Hit
        'hit_below': '(below the first symbol in this map)',
        'hit_stale': '(STALE)',

        # Summary
        'sum_header': '%-19s %-7s %-11s %-26s %-6s %s',
        'sum_note': "note: a ~ prefix means the symbol came from another build's map (a hint, not proof).",
        'sum_sigs': '--- signatures (exception + faulting function) ---',
        'sum_sig_line': '  {a:4d}x  {b}',

        # CLI
        'cli_desc': 'SeiunEngine crash triage: pick the crash report and the .map, get the crashing function.',
        'cli_epilog': 'With no switches this opens the window UI (tkinter); --tui or --no-gui uses the terminal UI.\nExit codes: 0 all matched, 1 some report is from another build, 2 nothing to do.',
        'help_crash': 'triage this crash report',
        'help_map': 'use this linker .map (default: auto)',
        'help_all': 'triage every report in the crash dir',
        'help_pick': 'choose the report with a file dialog',
        'help_summary': 'one line per report + signature counts',
        'help_json': 'machine-readable summary output',
        'help_keep_map': "snapshot the current build's .map",
        'help_clean': 'archive old reports',
        'help_keep': 'keep the newest N reports (default 20)',
        'help_prune_maps': 'keep only the newest N map snapshots',
        'help_dry_run': '--clean: do not move or delete anything',
        'help_frames': 'how many app frames to symbolise (default 8)',
        'help_crash_dir': 'override the crash directory',
        'help_exe': 'override the exe used for the build fingerprint',
        'help_tui': 'terminal UI (never opens a window)',
        'help_no_gui': 'same as --tui, kept for scripting',
        'help_no_write': 'do not write <report>.triage.txt',
        'help_no_color': 'plain terminal output',
        'help_lang': 'UI language (en, zh)',
        'loading_map': '  loading map {v}...',
        'snapshotted': 'snapshotted: {v}',
        'already_snapshotted': 'already snapshotted: {v}',
        'archive_moved': 'moved {v} item(s)',
        'archive_would_move': 'would move {v} item(s)',
        'and_more': '  ... and {v} more',
        'no_snapshots': '  no snapshots in {v}',
        'summary_crash_dir': 'crash dir : {v}',
        'summary_current': 'current   : {v}   ({m})',
        'summary_reports': 'reports   : {v}',
        'summary_map': 'map       : {v}   [{q}]',
    },
    'zh': {
        'err_not_map': '不是链接器 .map 文件 (没有首选加载地址): {v}',
        'err_map_not_found': '找不到 map 文件: {v}',
        'err_exe_not_found': '找不到 exe 文件: {v}',
        'err_report_not_found': '找不到报告文件: {v}',
        'err_no_reports': '{v} 中没有崩溃报告',
        'err_nothing_picked': '未选择任何文件',
        'ok': '成功', 'fail': '失败', 'skip': '跳过', 'stale': '过期', 'match': '匹配', 'other': '不匹配',
        'ready': '就绪', 'done': '完成', 'summary_done': '摘要完成', 'keep_map_done': '快照完成', 'archive_done': '归档完成',
        
        # TUI
        'tui_title': 'SeiunEngine 崩溃分析',
        'tui_crash_dir': '  崩溃目录 : {v}',
        'tui_reports': '  报告数量 : {v}',
        'tui_current': '  当前构建 : {v}   ({m})',
        'tui_no_current': '  当前构建 : (未找到 SeiunEngine.exe)',
        'tui_map_chosen': '  map 文件 : {v}   (手动选择)',
        'tui_map_auto': '  map 文件 : 自动 (优先匹配报告构建的快照，否则使用当前构建)',
        'menu_newest': '  1  分析最新的报告',
        'menu_listed': '  2  分析列表中的报告 (按编号)',
        'menu_dialog': '  3  通过文件对话框选择崩溃报告',
        'menu_all': '  4  分析全部报告',
        'menu_summary': '  5  摘要表格',
        'menu_keep_map': '  6  立即保存当前 .map 快照 (keep-map)',
        'menu_list_maps': '  7  列出 .map 快照',
        'menu_archive': '  8  归档旧报告 (保留最新 20 个)',
        'menu_choose_map': '  9  选择从此以后使用的 .map 文件',
        'menu_help_quit': '  h  帮助        q  退出',
        'tui_help_1': '报告只有匹配产生它的构建的 .map 时才准确。',
        'tui_help_2': '每次构建后请保存快照 (菜单 6)；来自其他构建的符号会被标记为过期。',
        'tui_out_of_range': '  超出范围',
        'tui_no_reports_here': '  这里没有报告',
        'tui_nothing_picked': '  (未选择)',
        'tui_nothing_picked_auto': '  (未选择 - 使用自动)',
        'tui_map_for_report': '此报告使用的 Map 文件:',
        'tui_auto_map': '  [Enter] 自动  ->  {v}   [{q}]',
        'tui_auto_map_none': '  [Enter] 自动  ->  (未找到)',
        'tui_pick_map_dialog': '  [p]           ->  通过文件对话框选择 .map',
        'tui_paste_map_path': '  [路径]        ->  直接粘贴 .map 文件路径',
        'tui_use_which_map': '从此以后使用哪个 .map？',
        'tui_auto_map_back': '  [Enter] 自动  ->  恢复自动',
        'tui_triage_result_ok': '结果：{v} 个报告，全部匹配该 map',
        'tui_triage_result_stale': '结果：{a} 个报告，{b} 个来自其他构建 (符号仅为提示)',

        # GUI
        'gui_title': 'SeiunEngine 崩溃分析',
        'gui_inputs': ' 输入 (选择崩溃报告和 map 文件) ',
        'gui_crash_report': '崩溃报告',
        'gui_map_file': 'Map 文件',
        'gui_browse': '浏览...',
        'gui_use_map': '使用此 .map (不勾选 = 自动：优先匹配报告构建的快照，否则使用当前构建)',
        'gui_reports': ' 崩溃报告 (最新的在前；单击=选择，双击=分析) ',
        'gui_output': ' 输出 (CI 风格步骤 + 报告详情) ',
        'btn_triage_selected': '分析选中项',
        'btn_triage_all': '分析全部报告',
        'btn_summary': '摘要',
        'btn_snapshot': '保存当前 .map 快照',
        'btn_archive': '归档旧报告',
        'btn_clear': '清空输出',
        'btn_quit': '退出',
        'gui_cur_build': '当前构建: {v}  ({m})',
        'gui_no_cur_build': '当前构建: (未找到 SeiunEngine.exe)',
        'gui_auto_map': '自动 map: {v}   [{q}]',
        'gui_auto_map_none': '自动 map: (未找到)',
        'gui_note_exe_missing': '注意: 未找到 SeiunEngine.exe，无法检查构建匹配。',
        'gui_pick_report_first': '选择一个崩溃报告 (点击浏览或单击列表)，可选选择一个 .map 文件，然后点击按钮。',
        'gui_choose_report_title': '选择崩溃报告',
        'gui_choose_map_title': '选择链接器 .map',
        'gui_all_files': '所有文件',
        'gui_crash_reports': '崩溃报告',
        'gui_map_files': 'Map 文件',

        # 列名
        'col_date': '日期', 'col_name': '名称', 'col_kind': '类型', 'col_exception': '异常', 'col_state': '状态', 'col_build': '构建', 'col_symbol': '崩溃函数',

        # Steps
        'step_read_report': '读取报告',
        'step_fingerprint': '报告构建指纹',
        'step_select_map': '选择 .map',
        'step_load_map': '加载 .map',
        'step_compare': '对比构建',
        'step_resolve_fault': '解析崩溃偏移',
        'step_resolve_bt': '解析调用栈',
        'step_write': '写入分析文件',
        'step_skip_no_stamp': '此旧版报告未记录该信息',
        'step_no_map': '未找到 - 请使用 -m/--map 或 --keep-map 保存快照',
        'step_map_cached': '已缓存 ({v} 个函数)',
        'step_map_loaded': '{a:.1f} MB, {b} 个函数, {c:.1f}s',
        'step_build_exact': '此 map 就是产生此报告的构建',
        'step_build_stale': '报告构建 {a} vs 当前构建 {b}',
        'step_build_no_cur': '未找到当前 exe',
        'step_fault_detail': '0x{a:X} -> {b}',
        'step_bt_detail': '无崩溃偏移 (abort/terminate 路径)；{a} 个应用栈帧，首个: 0x{b:X} -> {c}',
        'step_bt_skip': '调用栈中没有 SeiunEngine.exe 的帧',
        'step_haxe': '此报告没有崩溃偏移 (Haxe 层崩溃)',
        'step_posix': '没有 Windows 崩溃偏移/调用栈 (POSIX 报告？请使用 tools/symbolize_android.py)',
        'step_no_map_loaded': '未加载 map',
        'step_write_ok': '{v}',
        'step_write_skip': '已禁用 (--no-write)',
        'step_quality_chosen_exact': '手动选择 (与报告构建匹配)',
        'step_quality_chosen_hint': '手动选择 (无法针对此报告验证)',
        'step_quality_snapshot': '此构建的快照',
        'step_quality_current': '当前构建',
        'step_quality_current_nostamp': '当前构建 (报告无构建标记)',
        'step_quality_current_mismatch': '当前构建 (不匹配 - 此报告来自其他构建)',

        # Report Block
        'rep_app': '  应用         : {v}',
        'rep_engine': '  引擎         : {v}',
        'rep_exception': '  异常         : {v}{n}',
        'rep_context': '  上下文       : {v}',
        'rep_fault_module': '  崩溃模块     : {v}',
        'rep_error': '  错误         : {v}',
        'rep_build': '  报告构建     : {v}',
        'rep_no_build': '(旧版报告未记录)',
        'rep_cur_exe': '  当前 exe     : {v}',
        'rep_not_built': '(未构建)',
        'rep_match_yes': '  构建匹配     : 是 - 此 map 就是产生此报告的构建',
        'rep_match_no': '  构建匹配     : 否 - 此 map 来自其他构建；下方的符号仅供参考',
        'rep_map': '  map 文件     : {v}',
        'rep_no_map': '(未找到)',
        'rep_fault_offset': '  崩溃偏移     : 0x{v:X}',
        'rep_fault_hit': '        -> {v}',
        'rep_call_stack': '  调用栈 (应用模块，前 {v} 个):',
        'rep_stack_line': '      #{a:02d} 0x{b:X} -> {c}',
        'rep_no_fault_abort': '  崩溃偏移     : (无 - abort()/terminate() 路径，没有触发崩溃的指令)',
        'rep_no_fault_haxe': '  崩溃偏移     : (此报告没有崩溃偏移 - Haxe 层崩溃，无需解析符号)',
        'rep_no_fault_posix': '  崩溃偏移     : (原生报告缺少 Windows 崩溃偏移/调用栈 - POSIX dump 请使用 tools/symbolize_android.py)',

        # Hit
        'hit_below': '(低于此 map 中的第一个符号)',
        'hit_stale': '(过期)',

        # Summary
        'sum_header': '%-19s %-7s %-11s %-26s %-6s %s',
        'sum_note': "注意：带有 ~ 前缀表示该符号来自其他构建的 map (仅供参考，并非确凿证据)。",
        'sum_sigs': '--- 签名 (异常 + 崩溃函数) ---',
        'sum_sig_line': '  {a:4d}x  {b}',

        # CLI
        'cli_desc': 'SeiunEngine 崩溃分析：选择崩溃报告和 .map 文件，找出崩溃的函数。',
        'cli_epilog': '不带参数运行将打开窗口 UI (tkinter)；使用 --tui 或 --no-gui 运行终端 UI。\n退出码：0 全部匹配，1 部分报告来自其他构建，2 没有要处理的内容。',
        'help_crash': '分析此崩溃报告',
        'help_map': '使用此链接 .map 文件 (默认：自动)',
        'help_all': '分析崩溃目录中的全部报告',
        'help_pick': '通过文件对话框选择报告',
        'help_summary': '每个报告一行摘要 + 签名统计',
        'help_json': '输出机器可读的摘要',
        'help_keep_map': '保存当前构建的 .map 快照',
        'help_clean': '归档旧报告',
        'help_keep': '保留最新的 N 个报告 (默认 20)',
        'help_prune_maps': '仅保留最新的 N 个 map 快照',
        'help_dry_run': '--clean：不移动或删除任何内容',
        'help_frames': '解析多少个应用栈帧 (默认 8)',
        'help_crash_dir': '覆盖崩溃目录',
        'help_exe': '覆盖用于构建指纹的 exe',
        'help_tui': '终端 UI (不打开窗口)',
        'help_no_gui': '与 --tui 相同，用于脚本',
        'help_no_write': '不写入 <report>.triage.txt',
        'help_no_color': '纯文本终端输出',
        'help_lang': '界面语言 (en, zh)',
        'loading_map': '  加载 map {v}...',
        'snapshotted': '快照已保存: {v}',
        'already_snapshotted': '快照已存在: {v}',
        'archive_moved': '已移动 {v} 个项目',
        'archive_would_move': '将移动 {v} 个项目',
        'and_more': '  ... 以及另外 {v} 个',
        'no_snapshots': '  {v} 中没有快照',
        'summary_crash_dir': '崩溃目录 : {v}',
        'summary_current': '当前构建 : {v}   ({m})',
        'summary_reports': '报告数量 : {v}',
        'summary_map': 'map 文件 : {v}   [{q}]',
    }
}

def _pre_scan_lang():
    for i, arg in enumerate(sys.argv):
        if arg == '--lang' and i + 1 < len(sys.argv):
            return sys.argv[i+1]
    return None

CURRENT_LANG = _pre_scan_lang()
if not CURRENT_LANG:
    try:
        lang, _ = locale.getdefaultlocale()
        CURRENT_LANG = 'zh' if lang and lang.lower().startswith('zh') else 'en'
    except Exception:
        CURRENT_LANG = 'en'

def _(key, **kwargs):
    """全局翻译函数"""
    lang_dict = TRANSLATIONS.get(CURRENT_LANG, TRANSLATIONS['en'])
    text = lang_dict.get(key, TRANSLATIONS['en'].get(key, key))
    if kwargs:
        try:
            return text.format(**kwargs)
        except Exception:
            return text
    return text

# ============================================================================
# 核心逻辑
# ============================================================================

TOOL_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(TOOL_DIR)
DEFAULT_CRASH_DIR = os.path.join(REPO_ROOT, 'export', 'release', 'windows', 'bin', 'crash')

def _first_existing(*paths):
    for p in paths:
        if os.path.isfile(p):
            return p
    return paths[0]

def _newest_existing(*paths):
    existing = [p for p in paths if os.path.isfile(p)]
    if not existing:
        return paths[0]
    return max(existing, key=os.path.getmtime)


DEFAULT_MAP = _newest_existing(
    os.path.join(REPO_ROOT, 'export', 'symbols', 'windows-release', 'ApplicationMain.map'),
    os.path.join(REPO_ROOT, 'export', 'release', 'windows', 'obj', 'ApplicationMain.map'))
DEFAULT_EXE = os.path.join(REPO_ROOT, 'export', 'release', 'windows', 'bin', 'SeiunEngine.exe')

REPORT_PREFIXES = ('native_crash', 'SeiunEngine_', 'MohonghEngine_')
MAP_LINE = re.compile(r'^\s+[0-9a-fA-F]{4}:[0-9a-fA-F]{8}\s+(\S+)\s+([0-9a-fA-F]{16})\s+([fi ]+?)\s+(\S+)\s*$')
BASE_LINE = re.compile(r'Preferred load address is\s+([0-9a-fA-F]+)')
NAME_DATE = re.compile(r"(\d{4})-(\d{2})-(\d{2})_(\d{2})'(\d{2})'(\d{2})")
NAME_DATE_COMPACT = re.compile(r'(\d{4})(\d{2})(\d{2})_(\d{2})(\d{2})(\d{2})')

FNV_OFFSET = 0x811C9DC5
FNV_PRIME = 0x01000193

def fnv1a_head_tail(path, chunk=65536):
    h = FNV_OFFSET
    size = os.path.getsize(path)
    with open(path, "rb") as fh:
        data = fh.read(chunk)
        for b in data:
            h = ((h ^ b) * FNV_PRIME) & 0xFFFFFFFF
        if size > chunk * 2:
            fh.seek(size - chunk)
            data = fh.read(chunk)
            for b in data:
                h = ((h ^ b) * FNV_PRIME) & 0xFFFFFFFF
    return "%08x" % h

def same_build(report, current):
    if not report or not current:
        return False
    report_hash = report.get("build_hash")
    if report_hash and current.get("hash") and report_hash.lower() == current["hash"].lower():
        return True
    return report_fingerprint(report) == current["fingerprint"]

def exe_fingerprint(path):
    if not path or not os.path.isfile(path):
        return None
    size = os.path.getsize(path)
    stamp = 0
    try:
        with open(path, 'rb') as fh:
            fh.seek(0x3C)
            pe_off = struct.unpack('<I', fh.read(4))[0]
            fh.seek(pe_off + 8)
            stamp = struct.unpack('<I', fh.read(4))[0]
    except Exception:
        stamp = 0
    try:
        build_hash = fnv1a_head_tail(path)
    except Exception:
        build_hash = None
    return {
        'path': os.path.abspath(path),
        'size': size,
        'stamp': stamp,
        'hash': build_hash,
        'modified': datetime.fromtimestamp(os.path.getmtime(path)).strftime('%Y-%m-%d %H:%M:%S'),
        'fingerprint': '%dB@%ds' % (size, stamp),
    }

def date_from_name(name):
    m = NAME_DATE.search(name) or NAME_DATE_COMPACT.search(name)
    if not m:
        return None
    g = m.groups()
    return '%s-%s-%s %s:%s:%s' % g

def report_files(crash_dir):
    if not os.path.isdir(crash_dir):
        return []
    out = []
    for name in os.listdir(crash_dir):
        if not name.endswith('.txt') or name.endswith('.triage.txt'):
            continue
        if not name.startswith(REPORT_PREFIXES):
            continue
        full = os.path.join(crash_dir, name)
        if os.path.isfile(full):
            out.append(full)
    out.sort(key=lambda p: os.path.getmtime(p))
    return out

def repo_defaults():
    return DEFAULT_CRASH_DIR, DEFAULT_MAP, DEFAULT_EXE

def _first(lines, pattern, group=1):
    rx = re.compile(pattern)
    for line in lines:
        m = rx.match(line)
        if m:
            return m.group(group).strip()
    return None

def read_report(path):
    path = os.path.abspath(path)
    with open(path, 'r', encoding='utf-8', errors='replace') as fh:
        lines = fh.read().splitlines()

    head = lines[:40]
    exc = _first(head, r'^Exception code:\s*(0x[0-9a-fA-F]+)')
    fault_text = _first(head, r'^Fault offset:\s*(0x[0-9a-fA-F]+)')
    kind_text = _first(head, r'^Kind:\s*(.+)$')
    if exc or fault_text or (kind_text and 'Native crash' in kind_text):
        kind = 'native'
    elif _first(head, r'^(=== .*Crash Report ===)'):
        kind = 'haxe'
    else:
        kind = 'unknown'

    build_raw = _first(lines, r'^Build:\s*SeiunEngine\.exe=(\d+B@\d+s#[0-9a-fA-F]+)')
    build_size = build_stamp = build_hash = None
    if build_raw:
        m = re.match(r'^(\d+)B@(\d+)s#([0-9a-fA-F]+)$', build_raw)
        if m:
            build_size = int(m.group(1))
            build_stamp = int(m.group(2))
            build_hash = m.group(3)

    context = _first(lines, r'^Context:\s*(.+)$')
    ctx_state = ctx_song = None
    if context:
        m = re.search(r'state=([^|\s]+)', context)
        if m:
            ctx_state = m.group(1)
        m = re.search(r'song=([^|\s]+)', context)
        if m:
            ctx_song = m.group(1)

    frames = []
    in_bt = False
    for line in lines:
        if re.match(r'^(---\s*)?Backtrace', line):
            in_bt = True
            continue
        if in_bt and re.match(r'^(---\s*)?Stack scan', line):
            break
        if not in_bt:
            continue
        m = re.match(r'^\s+#(\d+)\s+(\S+?)\+0x([0-9a-fA-F]+)', line)
        if m:
            frames.append({'index': int(m.group(1)), 'module': m.group(2), 'offset': int(m.group(3), 16)})

    error_text = ''
    for i, line in enumerate(lines):
        if re.match(r'^Error:\s*$', line):
            chunks = []
            for nxt in lines[i + 1:]:
                if not nxt.strip():
                    break
                chunks.append(nxt.strip())
            error_text = ' '.join(chunks).strip()
            break

    haxe_stack = []
    for i, line in enumerate(lines):
        if re.match(r'^Stack Trace:\s*$', line):
            for nxt in lines[i + 1:]:
                if nxt.startswith('=== '):
                    break
                if nxt.strip():
                    haxe_stack.append(nxt.strip())
            break
    if haxe_stack and haxe_stack[0].startswith('(empty'):
        haxe_stack = []

    date = _first(lines, r'^Date:\s*(.+)$') or date_from_name(os.path.basename(path))
    return {
        'path': path,
        'name': os.path.basename(path),
        'kind': kind,
        'date': date,
        'exception': exc,
        'exception_name': _first(lines, r'^Exception code:\s*0x[0-9a-fA-F]+\s*\(([^)]*)\)'),
        'fault_offset': int(fault_text, 16) if fault_text else None,
        'faulting_module': _first(lines, r'^Faulting module:\s*(.+)$'),
        'app': _first(lines, r'^App:\s*(.+)$'),
        'engine': _first(lines, r'^Engine:\s*(.+)$'),
        'build_raw': build_raw,
        'build_size': build_size,
        'build_stamp': build_stamp,
        'build_hash': build_hash,
        'context': context,
        'state': ctx_state,
        'song': ctx_song,
        'backtrace': frames,
        'error': error_text,
        'haxe_stack': haxe_stack,
    }

def report_fingerprint(report):
    if report.get('build_size') is None:
        return None
    return '%dB@%ds' % (report['build_size'], report['build_stamp'])

def name_score(name):
    if name.startswith('$') or name.startswith('__real@') or name.startswith('__xmm@') or name.startswith('__guard_'):
        return 0
    if name.startswith('?'):
        return 3
    if name.startswith('_'):
        return 2
    return 1

def human_name(name):
    if not name.startswith('?'):
        return name
    m = re.match(r'^\?([^@]+)@(.*?)@@', name)
    if not m:
        return name[1:]
    scope = [part for part in m.group(2).split('@') if part]
    scope.reverse()
    return '::'.join(scope + [m.group(1)])

class MapData:
    def __init__(self, path, base, names, size, elapsed):
        self.path = path
        self.base = base
        self.names = names
        self.keys = sorted(names)
        self.size = size
        self.elapsed = elapsed

def read_map(path, log=None):
    path = os.path.abspath(path)
    size = os.path.getsize(path)
    if log:
        log(_('loading_map', v=os.path.basename(path), m=(size / (1024.0 * 1024.0))))
    started = time.time()
    base = 0
    names = {}
    score = {}
    with open(path, 'r', encoding='utf-8', errors='replace') as fh:
        for line in fh:
            if not base:
                m = BASE_LINE.search(line)
                if m:
                    base = int(m.group(1), 16)
            m = MAP_LINE.match(line)
            if not m:
                continue
            if 'f' not in m.group(3):
                continue
            rva = int(m.group(2), 16) - base
            name = m.group(1)
            prev = names.get(rva)
            if prev is not None:
                if name_score(name) <= score[rva]:
                    continue
            names[rva] = (name, m.group(4))
            score[rva] = name_score(name)
    if not base:
        raise ValueError(_('err_not_map', v=path))
    return MapData(path, base, names, size, time.time() - started)

def resolve_offset(map_data, offset):
    import bisect
    keys = map_data.keys
    idx = bisect.bisect_right(keys, offset) - 1
    if idx < 0:
        return None
    rva = keys[idx]
    name, obj = map_data.names[rva]
    return {'symbol': human_name(name), 'obj': obj, 'displacement': offset - rva}

def format_hit(hit, stale=False):
    if not hit:
        return _('hit_below')
    text = '%s + 0x%X' % (hit['symbol'], hit['displacement'])
    if hit['obj']:
        text += '   [%s]' % hit['obj']
    if stale:
        text += '   ' + _('hit_stale')
    return text

def app_backtrace_frames(report, limit=8):
    out = []
    for frame in report.get('backtrace') or []:
        if 'SeiunEngine.exe' in frame['module']:
            out.append(frame)
            if len(out) >= limit:
                break
    return out

def maps_dir(crash_dir):
    return os.path.join(crash_dir, 'maps')

def select_map(report, forced_map, current, crash_dir, default_map=None):
    default_map = default_map or DEFAULT_MAP
    fp = report_fingerprint(report) if report else None
    if forced_map:
        if not os.path.isfile(forced_map):
            raise FileNotFoundError(_('err_map_not_found', v=forced_map))
        path = os.path.abspath(forced_map)
        exact = bool(fp) and (os.path.splitext(os.path.basename(path))[0] == fp or same_build(report, current))
        quality = _('step_quality_chosen_exact') if exact else _('step_quality_chosen_hint')
        return {'path': path, 'exact': exact, 'quality': quality}
    if fp:
        snap = os.path.join(maps_dir(crash_dir), fp + '.map')
        if os.path.isfile(snap):
            return {'path': snap, 'exact': True, 'quality': _('step_quality_snapshot')}
    if os.path.isfile(default_map):
        exact = same_build(report, current)
        if exact:
            quality = _('step_quality_current')
        elif not fp:
            quality = _('step_quality_current_nostamp')
        else:
            quality = _('step_quality_current_mismatch')
        return {'path': os.path.abspath(default_map), 'exact': exact, 'quality': quality}
    return None

def analyze(report_path, forced_map, current, crash_dir, frames=8, map_cache=None,
            default_map=None, write=True, log=None):
    map_cache = map_cache if map_cache is not None else {}
    steps = []

    def step(title, status, detail=''):
        steps.append({'title': title, 'status': status, 'detail': detail})

    report = read_report(report_path)
    step(_('step_read_report'), 'OK', '%s  [%s]%s' % (report['name'], report['kind'],
         ('  ' + report['date']) if report['date'] else ''))

    fp = report_fingerprint(report)
    if fp:
        step(_('step_fingerprint'), 'OK', fp + ('#' + report['build_hash'] if report['build_hash'] else ''))
    else:
        step(_('step_fingerprint'), 'SKIP', _('step_skip_no_stamp'))

    info = select_map(report, forced_map, current, crash_dir, default_map)
    if info:
        step(_('step_select_map'), 'OK', '%s   [%s]' % (info['path'], info['quality']))
    else:
        step(_('step_select_map'), 'FAIL', _('step_no_map'))

    map_data = None
    if info:
        if info['path'] in map_cache:
            map_data = map_cache[info['path']]
            step(_('step_load_map'), 'OK', _('step_map_cached', v=len(map_data.keys)))
        else:
            map_data = read_map(info['path'], log=None)
            map_cache[info['path']] = map_data
            step(_('step_load_map'), 'OK', _('step_map_loaded', a=(map_data.size / (1024.0 * 1024.0)), b=len(map_data.keys), c=map_data.elapsed))

    stale = not (info and info['exact'])
    if info and info['exact']:
        step(_('step_compare'), 'OK', _('step_build_exact'))
    elif current:
        step(_('step_compare'), 'STALE', _('step_build_stale', a=(fp or '(none)'), b=current['fingerprint']))
    else:
        step(_('step_compare'), 'STALE', _('step_build_no_cur'))

    if map_data and report['fault_offset'] is not None:
        hit = resolve_offset(map_data, report['fault_offset'])
        step(_('step_resolve_fault'), 'OK', _('step_fault_detail', a=report['fault_offset'], b=format_hit(hit, stale)))
    elif map_data and report['kind'] == 'native' and report['backtrace']:
        app_frames = app_backtrace_frames(report, frames)
        if app_frames:
            hit = resolve_offset(map_data, app_frames[0]['offset'])
            step(_('step_resolve_bt'), 'OK', _('step_bt_detail', a=len(app_frames), b=app_frames[0]['offset'], c=format_hit(hit, stale)))
        else:
            step(_('step_resolve_bt'), 'SKIP', _('step_bt_skip'))
    elif map_data:
        detail = _('step_haxe')
        if report['kind'] == 'native':
            detail = _('step_posix')
        step(_('step_resolve_fault'), 'SKIP', detail)
    else:
        step(_('step_resolve_fault'), 'SKIP', _('step_no_map_loaded'))

    block = report_block(report, info, map_data, current, frames, stale)

    written = None
    if write:
        try:
            dest = os.path.splitext(report['path'])[0] + '.triage.txt'
            with open(dest, 'w', encoding='utf-8', newline='') as fh:
                fh.write('\n'.join(block) + '\n')
            written = dest
            step(_('step_write'), 'OK', _('step_write_ok', v=dest))
        except OSError as exc:
            step(_('step_write'), 'FAIL', str(exc))
    else:
        step(_('step_write'), 'SKIP', _('step_write_skip'))

    return {'report': report, 'steps': steps, 'block': block, 'stale': stale, 'written': written,
            'map': info, 'fingerprint': fp}

def report_block(report, info, map_data, current, frames, stale):
    out = []
    out.append('=' * 78)
    head = '%s   [%s]' % (report['name'], report['kind'])
    if report['date']:
        head += '   ' + report['date']
    out.append(head)
    out.append('=' * 78)
    
    if report['app']:
        out.append(_('rep_app', v=report['app']))
    elif report['engine']:
        out.append(_('rep_engine', v=report['engine']))
        
    if report['kind'] == 'native':
        name = ' (%s)' % report['exception_name'] if report['exception_name'] else ''
        out.append(_('rep_exception', v=report['exception'], n=name))
        if report['context']:
            out.append(_('rep_context', v=report['context']))
        if report['faulting_module']:
            out.append(_('rep_fault_module', v=os.path.basename(report['faulting_module'])))
            
    if report['error']:
        out.append(_('rep_error', v=report['error']))
    for line in report['haxe_stack']:
        out.append('      ' + line)
        
    out.append(_('rep_build', v=(report['build_raw'] or _('rep_no_build'))))
    out.append(_('rep_cur_exe', v=(current['fingerprint'] + '   (' + current['modified'] + ')' if current else _('rep_not_built'))))
    
    if info and info['exact']:
        out.append(_('rep_match_yes'))
    else:
        out.append(_('rep_match_no'))
        
    out.append(_('rep_map', v=('%s   [%s]' % (info['path'], info['quality']) if info else _('rep_no_map'))))

    if map_data and report['fault_offset'] is not None:
        out.append(_('rep_fault_offset', v=report['fault_offset']))
        out.append(_('rep_fault_hit', v=format_hit(resolve_offset(map_data, report['fault_offset']), stale)))
        app_frames = [f for f in report['backtrace'] if 'SeiunEngine.exe' in f['module']][:frames]
        if app_frames:
            out.append(_('rep_call_stack', v=len(app_frames)))
            for f in app_frames:
                hit = resolve_offset(map_data, f['offset'])
                out.append(_('rep_stack_line', a=f['index'], b=f['offset'], c=format_hit(hit, stale)))
    elif map_data:
        if report['kind'] == 'native' and report['backtrace']:
            app_frames = app_backtrace_frames(report, frames)
            out.append(_('rep_no_fault_abort'))
            if app_frames:
                out.append(_('rep_call_stack', v=len(app_frames)))
                for f in app_frames:
                    hit = resolve_offset(map_data, f['offset'])
                    out.append(_('rep_stack_line', a=f['index'], b=f['offset'], c=format_hit(hit, stale)))
        else:
            msg = _('rep_no_fault_haxe')
            if report['kind'] == 'native':
                msg = _('rep_no_fault_posix')
            out.append(msg)
    out.append('')
    return out

def summary_rows(crash_dir, current, map_data):
    rows = []
    for path in reversed(report_files(crash_dir)):
        report = read_report(path)
        fp = report_fingerprint(report)
        match = bool(current and same_build(report, current))
        symbol = ''
        if map_data and report['fault_offset'] is not None:
            hit = resolve_offset(map_data, report['fault_offset'])
            if hit:
                symbol = '%s + 0x%X' % (hit['symbol'], hit['displacement'])
                if not match:
                    symbol = '~ ' + symbol
        elif map_data and report['kind'] == 'native' and report['backtrace']:
            frames = app_backtrace_frames(report, 1)
            hit = resolve_offset(map_data, frames[0]['offset']) if frames else None
            if hit:
                symbol = '%s + 0x%X' % (hit['symbol'], hit['displacement'])
                if not match:
                    symbol = '~ ' + symbol
        rows.append({
            'name': report['name'], 'date': report['date'] or '', 'kind': report['kind'],
            'exception': report['exception'] or '-', 'state': report['state'] or '',
            'song': report['song'], 'buildMatch': match,
            'faultOffset': ('0x%X' % report['fault_offset']) if report['fault_offset'] is not None else None,
            'symbol': symbol,
        })
    return rows

def keep_map(map_path, crash_dir, exe_path, force=False):
    src = map_path or DEFAULT_MAP
    if not os.path.isfile(src):
        raise FileNotFoundError(_('err_map_not_found', v=src))
    current = exe_fingerprint(exe_path)
    if not current:
        raise FileNotFoundError(_('err_exe_not_found', v=exe_path))
    out_dir = maps_dir(crash_dir)
    os.makedirs(out_dir, exist_ok=True)
    dest = os.path.join(out_dir, current['fingerprint'] + '.map')
    if os.path.isfile(dest) and not force:
        return {'path': dest, 'skipped': True, 'fingerprint': current['fingerprint']}
    import hashlib
    import shutil
    shutil.copyfile(src, dest)
    digest = hashlib.sha256(open(dest, 'rb').read()).hexdigest().upper()
    side = {
        'fingerprint': current['fingerprint'], 'exeBytes': current['size'],
        'peTimestamp': current['stamp'], 'exe': current['path'], 'mapSource': os.path.abspath(src),
        'mapBytes': os.path.getsize(dest), 'mapSha256': digest,
        'savedAt': datetime.now().strftime('%Y-%m-%d %H:%M:%S'),
    }
    with open(os.path.splitext(dest)[0] + '.json', 'w', encoding='utf-8') as fh:
        json.dump(side, fh, indent=2)
    return {'path': dest, 'skipped': False, 'fingerprint': current['fingerprint'],
            'bytes': side['mapBytes'], 'sha256': digest}

def clean(crash_dir, keep=20, prune_maps=0, dry_run=False):
    moved = []
    reports = list(reversed(report_files(crash_dir)))
    for report in reports[keep:]:
        stamp = date_from_name(os.path.basename(report))
        bucket = (stamp or datetime.fromtimestamp(os.path.getmtime(report)).strftime('%Y-%m-%d'))[:7]
        dest_dir = os.path.join(crash_dir, 'archive', bucket)
        trio = [report] + [p for p in [os.path.splitext(report)[0] + '.triage.txt'] if os.path.isfile(p)]
        for item in trio:
            target = os.path.join(dest_dir, os.path.basename(item))
            if not dry_run:
                os.makedirs(dest_dir, exist_ok=True)
                os.replace(item, target)
            moved.append(target)
    if prune_maps > 0:
        out_dir = maps_dir(crash_dir)
        if os.path.isdir(out_dir):
            snaps = [os.path.join(out_dir, n) for n in os.listdir(out_dir) if n.endswith('.map')]
            snaps.sort(key=os.path.getmtime, reverse=True)
            for old in snaps[prune_maps:]:
                if not dry_run:
                    os.remove(old)
                    side = os.path.splitext(old)[0] + '.json'
                    if os.path.isfile(side):
                        os.remove(side)
                moved.append(old)
    return moved

_CODES = {'reset': '\033[0m', 'dim': '\033[2m', 'bold': '\033[1m', 'red': '\033[31m',
          'green': '\033[32m', 'yellow': '\033[33m', 'cyan': '\033[36m'}
USE_COLOR = False

def enable_ansi():
    global USE_COLOR
    if os.name != 'nt':
        USE_COLOR = bool(getattr(sys.stdout, 'isatty', lambda: False)())
        return USE_COLOR
    try:
        import ctypes
        kernel32 = ctypes.windll.kernel32
        handle = kernel32.GetStdHandle(-11)
        mode = ctypes.c_uint32()
        if not kernel32.GetConsoleMode(handle, ctypes.byref(mode)):
            USE_COLOR = False
            return False
        kernel32.SetConsoleMode(handle, mode.value | 0x0004)
        USE_COLOR = True
    except Exception:
        USE_COLOR = False
    return USE_COLOR

def col(text, name):
    if not USE_COLOR:
        return text
    return _CODES.get(name, '') + text + _CODES['reset']

STATUS_COLOR = {'OK': 'green', 'STALE': 'yellow', 'WARN': 'yellow', 'FAIL': 'red', 'SKIP': 'dim'}

def step_plain(steps, width=76):
    out = []
    total = len(steps)
    for i, item in enumerate(steps, 1):
        label = '[ %d/%d ] %s ' % (i, total, item['title'])
        dots = '.' * max(2, width - len(label))
        line = label + dots + ' ' + item['status'].ljust(5)
        if item['detail']:
            line += '  ' + item['detail']
        out.append((line, item['status']))
    return out

def step_lines(steps, width=76):
    out = []
    for line, status in step_plain(steps, width):
        marker = status.ljust(5)
        idx = line.find(marker)
        if idx >= 0:
            line = line[:idx] + col(marker, STATUS_COLOR.get(status, 'reset')) + line[idx + len(marker):]
        out.append(line)
    return out

def ruler(title='', width=78):
    if not title:
        return '=' * width
    pad = width - len(title) - 3
    return '== ' + title + ' ' + '=' * max(0, pad)

def pick_file(title, filetypes, initialdir=None, save=False):
    try:
        import tkinter as tk
        from tkinter import filedialog
    except Exception:
        return None
    try:
        root = tk.Tk()
        root.withdraw()
        try:
            root.attributes('-topmost', True)
        except Exception:
            pass
        opts = {'title': title, 'filetypes': filetypes}
        if initialdir and os.path.isdir(initialdir):
            opts['initialdir'] = initialdir
        path = filedialog.asksaveasfilename(**opts) if save else filedialog.askopenfilename(**opts)
        root.destroy()
        return path or None
    except Exception:
        return None

def gui_available():
    try:
        import tkinter  # noqa: F401
        return True
    except Exception:
        return False

# ============================================================================
# GUI
# ============================================================================

def run_gui(crash_dir, exe_path, default_map, forced_map=None, frames=8):
    import queue
    import threading
    import tkinter as tk
    from tkinter import filedialog, ttk

    current = exe_fingerprint(exe_path)
    map_cache = {}
    jobs = queue.Queue()

    root = tk.Tk()
    root.title(_('gui_title'))
    root.geometry('1040x790+60+40')
    root.minsize(880, 640)
    mono = ('Consolas', 10) if os.name == 'nt' else ('Menlo', 11)

    inputs = ttk.LabelFrame(root, text=_('gui_inputs'))
    inputs.pack(fill='x', padx=10, pady=(10, 6))
    inputs.columnconfigure(1, weight=1)

    crash_var = tk.StringVar(value='')
    map_var = tk.StringVar(value=forced_map or '')
    use_map_var = tk.BooleanVar(value=bool(forced_map))

    def browse(var, title, patterns):
        initial = os.path.dirname(var.get()) if var.get() else crash_dir
        path = filedialog.askopenfilename(parent=root, title=title, initialdir=initial, filetypes=patterns)
        if path:
            var.set(path)
            if var is crash_var:
                update_info()
        return path

    ttk.Label(inputs, text=_('gui_crash_report')).grid(row=0, column=0, sticky='w', padx=6, pady=4)
    ttk.Entry(inputs, textvariable=crash_var).grid(row=0, column=1, sticky='ew', padx=6, pady=4)
    ttk.Button(inputs, text=_('gui_browse'), command=lambda: browse(crash_var, _('gui_choose_report_title'),
        [(_('gui_crash_reports'), '*.txt'), (_('gui_all_files'), '*.*')])).grid(row=0, column=2, padx=6, pady=4)

    ttk.Label(inputs, text=_('gui_map_file')).grid(row=1, column=0, sticky='w', padx=6, pady=4)
    ttk.Entry(inputs, textvariable=map_var).grid(row=1, column=1, sticky='ew', padx=6, pady=4)
    ttk.Button(inputs, text=_('gui_browse'), command=lambda: browse(map_var, _('gui_choose_map_title'),
        [(_('gui_map_files'), '*.map'), (_('gui_all_files'), '*.*')])).grid(row=1, column=2, padx=6, pady=4)

    ttk.Checkbutton(inputs, variable=use_map_var,
        text=_('gui_use_map')).grid(row=2, column=0, columnspan=3, sticky='w', padx=6, pady=(0, 2))
    info = ttk.Label(inputs, text='', foreground='#666666')
    info.grid(row=3, column=0, columnspan=3, sticky='w', padx=6, pady=(0, 6))

    mid = ttk.LabelFrame(root, text=_('gui_reports'))
    mid.pack(fill='both', padx=10, pady=6)
    cols = ('date', 'name', 'kind', 'exception')
    tree = ttk.Treeview(mid, columns=cols, show='headings', height=9)
    for name, width in zip(cols, (150, 430, 80, 130)):
        tree.heading(name, text=_(f'col_{name}'))
        tree.column(name, width=width, anchor='w')
    tree.pack(side='left', fill='both', expand=True, padx=(6, 0), pady=6)
    tree_sb = ttk.Scrollbar(mid, orient='vertical', command=tree.yview)
    tree_sb.pack(side='right', fill='y', pady=6)
    tree.configure(yscrollcommand=tree_sb.set)

    out_frame = ttk.LabelFrame(root, text=_('gui_output'))
    out_frame.pack(fill='both', expand=True, padx=10, pady=6)
    out = tk.Text(out_frame, wrap='none', font=mono, background='#0f1419', foreground='#d8dee9',
                  insertbackground='#d8dee9', height=16)
    out.pack(side='left', fill='both', expand=True, padx=(6, 0), pady=6)
    out_sb = ttk.Scrollbar(out_frame, orient='vertical', command=out.yview)
    out_sb.pack(side='right', fill='y', pady=6)
    out.configure(yscrollcommand=out_sb.set, state='disabled')
    for tag, colour in (('ok', '#7ec699'), ('stale', '#e6c07b'), ('fail', '#e06c75'),
                        ('dim', '#7f8c98'), ('head', '#61afef'), ('plain', '#d8dee9')):
        out.tag_configure(tag, foreground=colour)

    buttons = ttk.Frame(root)
    buttons.pack(fill='x', padx=10)
    status = tk.StringVar(value=_('ready'))
    ttk.Label(root, textvariable=status, anchor='w').pack(fill='x', padx=12, pady=(4, 8))

    def write(text, tag='plain'):
        out.configure(state='normal')
        out.insert('end', text + '\n', tag)
        out.see('end')
        out.configure(state='disabled')

    def post(kind, payload=None, tag='plain'):
        jobs.put((kind, payload, tag))

    def drain():
        try:
            while True:
                kind, payload, tag = jobs.get_nowait()
                try:
                    if kind == 'line':
                        write(payload, tag)
                    elif kind == 'status':
                        status.set(payload)
                    elif kind == 'busy':
                        set_busy(payload)
                    elif kind == 'refresh':
                        refresh_tree()
                    elif kind == 'see':
                        out.yview(payload)
                except Exception as exc:
                    write('UI error: %s' % exc, 'fail')
        except queue.Empty:
            pass
        root.after(60, drain)

    def set_busy(busy):
        state = 'disabled' if busy else 'normal'
        for widget in button_widgets:
            try:
                widget.configure(state=state)
            except Exception:
                pass

    def run_bg(job):
        set_busy(True)
        def worker():
            try:
                job()
            except Exception as exc:
                post('line', 'ERROR: %s' % exc, 'fail')
            finally:
                post('busy', False)
        threading.Thread(target=worker, daemon=True).start()

    def refresh_tree():
        tree.delete(*tree.get_children())
        files = list(reversed(report_files(crash_dir)))
        for path in files:
            try:
                report = read_report(path)
            except Exception:
                continue
            tree.insert('', 'end', iid=path, values=(report['date'] or '', report['name'],
                        report['kind'], report['exception'] or '-'))
        tree.yview_moveto(0)
        status.set('%d %s   |   %s' % (len(files), _('tui_reports').split(':')[0].strip(), crash_dir))
        if files and not crash_var.get():
            crash_var.set(files[0])
        update_info()

    def update_info():
        bits = []
        if current:
            bits.append(_('gui_cur_build', v=current['fingerprint'], m=current['modified']))
        else:
            bits.append(_('gui_no_cur_build'))
        report = None
        path = crash_var.get().strip()
        if path and os.path.isfile(path):
            try:
                report = read_report(path)
            except Exception:
                report = None
        auto = select_map(report, None, current, crash_dir, default_map)
        if auto:
            bits.append(_('gui_auto_map', v=auto['path'], q=auto['quality']))
        else:
            bits.append(_('gui_auto_map_none'))
        info.configure(text='        '.join(bits))

    def chosen_map():
        if not use_map_var.get():
            return None
        path = map_var.get().strip()
        if path and not os.path.isfile(path):
            raise FileNotFoundError(_('err_map_not_found', v=path))
        return path or None

    def all_reports():
        return list(reversed(report_files(crash_dir)))

    def selected_paths():
        sel = list(tree.selection())
        if sel:
            return sel
        path = crash_var.get().strip()
        if path and os.path.isfile(path):
            return [path]
        files = all_reports()
        return [files[0]] if files else []

    def on_select(_event=None):
        sel = tree.selection()
        if sel:
            crash_var.set(sel[0])
            update_info()

    def on_double(_event=None):
        paths = selected_paths()
        if paths:
            triage(paths)

    def triage(paths):
        start_index = out.index('end-1c')
        def job():
            forced = chosen_map()
            stale_total = 0
            for i, path in enumerate(paths):
                post('line', ruler('%s %d/%d   %s' % (_('tui_title'), i + 1, len(paths), os.path.basename(path))), 'head')
                result = analyze(path, forced, current, crash_dir, frames=frames, map_cache=map_cache,
                                 default_map=default_map, write=(len(paths) == 1))
                for line, st in step_plain(result['steps']):
                    post('line', line, {'OK': 'ok', 'STALE': 'stale', 'FAIL': 'fail'}.get(st, 'dim'))
                for line in result['block']:
                    post('line', line, 'plain')
                if result['stale']:
                    stale_total += 1
                post('line', '', 'plain')
            if stale_total == 0:
                post('line', _('tui_triage_result_ok', v=len(paths)), 'ok')
            else:
                post('line', _('tui_triage_result_stale', a=len(paths), b=stale_total), 'stale')
            post('see', start_index)
            post('status', _('done'))
        run_bg(job)

    def summary():
        def job():
            post('line', ruler(_('menu_summary')), 'head')
            info2 = select_map(None, chosen_map(), current, crash_dir, default_map)
            map_data = None
            if info2:
                if info2['path'] not in map_cache:
                    map_cache[info2['path']] = read_map(info2['path'])
                map_data = map_cache[info2['path']]
            rows = summary_rows(crash_dir, current, map_data)
            post('line', '%-19s %-7s %-11s %-26s %-6s %s' % (_('col_date'), _('col_kind'), _('col_exception'), _('col_state'), _('col_build'), _('col_symbol')), 'plain')
            post('line', '-' * 118, 'dim')
            for row in rows:
                post('line', '%-19s %-7s %-11s %-26s %-6s %s' % (
                    (row['date'] or '')[:18], row['kind'], row['exception'], (row['state'] or '')[:25],
                    _('match') if row['buildMatch'] else _('other'), row['symbol']), 'plain')
            for line in signature_lines(rows):
                post('line', line, 'plain')
            post('line', _('sum_note'), 'dim')
            post('status', _('summary_done'))
        run_bg(job)

    def keep():
        def job():
            post('line', ruler('keep-map'), 'head')
            source = map_var.get().strip() if use_map_var.get() else None
            result = keep_map(source, crash_dir, exe_path)
            if result['skipped']:
                post('line', _('already_snapshotted', v=result['path']), 'ok')
            else:
                post('line', _('snapshotted', v=result['path']), 'ok')
                post('line', 'fingerprint %s   %d B   sha256=%s' % (result['fingerprint'], result['bytes'], result['sha256']), 'plain')
            post('status', _('keep_map_done'))
        run_bg(job)

    def archive():
        def job():
            post('line', ruler(_('menu_archive')), 'head')
            moved = clean(crash_dir, keep=20, prune_maps=0, dry_run=False)
            post('line', _('archive_moved', v=len(moved)), 'ok')
            post('refresh', None)
            post('status', _('archive_done'))
        run_bg(job)

    button_widgets = []

    def add_button(text, command):
        widget = ttk.Button(buttons, text=text, command=command)
        widget.pack(side='left', padx=4, pady=4)
        button_widgets.append(widget)
        return widget

    add_button(_('btn_triage_selected'), lambda: triage(selected_paths()))
    add_button(_('btn_triage_all'), lambda: triage(all_reports()))
    add_button(_('btn_summary'), summary)
    add_button(_('btn_snapshot'), keep)
    add_button(_('btn_archive'), archive)
    add_button(_('btn_clear'), lambda: clear_output())
    add_button(_('btn_quit'), root.destroy)

    def clear_output():
        out.configure(state='normal')
        out.delete('1.0', 'end')
        out.configure(state='disabled')

    tree.bind('<<TreeviewSelect>>', on_select)
    tree.bind('<Double-1>', on_double)
    refresh_tree()
    drain()
    write(ruler(_('tui_title')), 'head')
    write(_('gui_pick_report_first'), 'dim')
    if not current:
        write(_('gui_note_exe_missing'), 'stale')
    root.mainloop()
    return 0

def signature_lines(rows):
    counts = {}
    for row in rows:
        symbol = row['symbol'] or ('(no symbol) ' + (row['state'] or ''))
        key = '%s  |  %s' % (row['exception'], symbol)
        counts[key] = counts.get(key, 0) + 1
    out = ['', _('sum_sigs')]
    for key in sorted(counts, key=lambda k: -counts[k]):
        out.append(_('sum_sig_line', a=counts[key], b=key))
    return out

# ============================================================================
# TUI
# ============================================================================

def run_tui(crash_dir, exe_path, default_map, forced_map=None, frames=8):
    if not USE_COLOR:
        enable_ansi()
    current = exe_fingerprint(exe_path)
    map_cache = {}
    forced = forced_map

    def ask(prompt):
        try:
            answer = input(prompt)
        except (EOFError, KeyboardInterrupt):
            return None
        return answer.lstrip('\ufeff').strip()

    def ask_map(report):
        auto = select_map(report, None, current, crash_dir, default_map)
        print()
        print(col(_('tui_map_for_report'), 'cyan'))
        if auto:
            print(_('tui_auto_map', v=auto['path'], q=auto['quality']))
        else:
            print(_('tui_auto_map_none'))
        print(_('tui_pick_map_dialog'))
        print(_('tui_paste_map_path'))
        answer = ask('> ')
        if not answer:
            return None
        if answer.lower() == 'p':
            picked = pick_file(_('gui_choose_map_title'), [(_('gui_map_files'), '*.map'), (_('gui_all_files'), '*.*')],
                               os.path.dirname(default_map))
            if picked:
                return picked
            print(col(_('tui_nothing_picked_auto'), 'yellow'))
            return None
        return answer.strip('"')

    def do_triage(paths, forced_map_choice):
        stale = 0
        for i, path in enumerate(paths):
            print()
            print(col(ruler('%s %d/%d   %s' % (_('tui_title'), i + 1, len(paths), os.path.basename(path))), 'cyan'))
            result = analyze(path, forced_map_choice, current, crash_dir, frames=frames, map_cache=map_cache,
                             default_map=default_map, write=(len(paths) == 1))
            for line in step_lines(result['steps']):
                print(line)
            print()
            for line in result['block']:
                print(line)
            if result['stale']:
                stale += 1
        print()
        if stale == 0:
            print(col(_('tui_triage_result_ok', v=len(paths)), 'green'))
        else:
            print(col(_('tui_triage_result_stale', a=len(paths), b=stale), 'yellow'))
        return stale

    while True:
        files = list(reversed(report_files(crash_dir)))
        print()
        print(col(ruler(_('tui_title')), 'cyan'))
        print(_('tui_crash_dir', v=crash_dir))
        print(_('tui_reports', v=len(files)))
        if current:
            print(_('tui_current', v=current['fingerprint'], m=current['modified']))
        else:
            print(col(_('tui_no_current'), 'yellow'))
        if forced:
            print(col(_('tui_map_chosen', v=forced), 'yellow'))
        else:
            print(_('tui_map_auto'))
        print()
        print(_('menu_newest'))
        print(_('menu_listed'))
        print(_('menu_dialog'))
        print(_('menu_all'))
        print(_('menu_summary'))
        print(_('menu_keep_map'))
        print(_('menu_list_maps'))
        print(_('menu_archive'))
        print(_('menu_choose_map'))
        print(_('menu_help_quit'))
        choice = ask('> ')
        if choice is None:
            print()
            return 0
        choice = choice.lower()
        if choice == 'q':
            return 0
        elif choice == 'h':
            print(_('tui_help_1'))
            print(_('tui_help_2'))
        elif choice == '1':
            if not files:
                print(col(_('tui_no_reports_here'), 'yellow'))
                continue
            report = read_report(files[0])
            picked = ask_map(report)
            if picked:
                forced = picked
            do_triage([files[0]], forced)
        elif choice == '2':
            if not files:
                print(col(_('tui_no_reports_here'), 'yellow'))
                continue
            for i, path in enumerate(files[:15], 1):
                print('  %3d) %s   %s' % (i, os.path.basename(path),
                      datetime.fromtimestamp(os.path.getmtime(path)).strftime('%Y-%m-%d %H:%M')))
            sel = ask('number> ')
            if sel and sel.isdigit() and 1 <= int(sel) <= min(15, len(files)):
                target = files[int(sel) - 1]
                report = read_report(target)
                picked = ask_map(report)
                if picked:
                    forced = picked
                do_triage([target], forced)
            elif sel:
                print(col(_('tui_out_of_range'), 'yellow'))
        elif choice == '3':
            picked = pick_file(_('gui_choose_report_title'), [(_('gui_crash_reports'), '*.txt'), (_('gui_all_files'), '*.*')], crash_dir)
            if not picked:
                print(col(_('tui_nothing_picked'), 'yellow'))
                continue
            report = read_report(picked)
            map_pick = ask_map(report)
            if map_pick:
                forced = map_pick
            do_triage([picked], forced)
        elif choice == '4':
            if not files:
                print(col(_('tui_no_reports_here'), 'yellow'))
                continue
            do_triage(files, forced)
        elif choice == '5':
            info = select_map(None, forced, current, crash_dir, default_map)
            map_data = None
            if info:
                if info['path'] not in map_cache:
                    map_cache[info['path']] = read_map(info['path'])
                map_data = map_cache[info['path']]
            rows = summary_rows(crash_dir, current, map_data)
            print()
            print('%-19s %-7s %-11s %-26s %-6s %s' % (_('col_date'), _('col_kind'), _('col_exception'), _('col_state'), _('col_build'), _('col_symbol')))
            print('-' * 118)
            for row in rows:
                print('%-19s %-7s %-11s %-26s %-6s %s' % (
                    (row['date'] or '')[:18], row['kind'], row['exception'], (row['state'] or '')[:25],
                    _('match') if row['buildMatch'] else _('other'), row['symbol']))
            for line in signature_lines(rows):
                print(line)
        elif choice == '6':
            try:
                result = keep_map(forced, crash_dir, exe_path)
            except Exception as exc:
                print(col('  ERROR: %s' % exc, 'red'))
                continue
            if result['skipped']:
                print(col(_('already_snapshotted', v=result['path']), 'green'))
            else:
                print(col(_('snapshotted', v=result['path']), 'green'))
                print('  fingerprint %s   %d B   sha256=%s' % (result['fingerprint'], result['bytes'], result['sha256']))
        elif choice == '7':
            out_dir = maps_dir(crash_dir)
            if not os.path.isdir(out_dir):
                print(_('no_snapshots', v=out_dir))
                continue
            for name in sorted(os.listdir(out_dir)):
                if name.endswith('.map'):
                    full = os.path.join(out_dir, name)
                    print('  %-30s %12d B' % (name, os.path.getsize(full)))
        elif choice == '8':
            moved = clean(crash_dir, keep=20, prune_maps=0, dry_run=False)
            print(col(_('archive_moved', v=len(moved)), 'green'))
        elif choice == '9':
            print()
            print(col(_('tui_use_which_map'), 'cyan'))
            print(_('tui_auto_map_back'))
            print(_('tui_pick_map_dialog'))
            print(_('tui_paste_map_path'))
            answer = ask('> ')
            if answer is None:
                return 0
            if answer == '':
                forced = None
            elif answer.lower() == 'p':
                picked = pick_file(_('gui_choose_map_title'), [(_('gui_map_files'), '*.map'), (_('gui_all_files'), '*.*')],
                                    os.path.dirname(default_map))
                if picked:
                    forced = picked
                else:
                    print(col(_('tui_nothing_picked'), 'yellow'))
            else:
                forced = answer.strip('"')
        else:
            print(col('  ?', 'yellow'))

# ============================================================================
# CLI
# ============================================================================

def print_summary(crash_dir, current, map_data, rows, map_info=None):
    print(_('summary_crash_dir', v=crash_dir))
    if current:
        print(_('summary_current', v=current['fingerprint'], m=current['modified']))
    print(_('summary_reports', v=len(rows)))
    if map_info:
        print(_('summary_map', v=map_info['path'], q=map_info['quality']))
    print()
    print('%-19s %-7s %-11s %-26s %-6s %s' % (_('col_date'), _('col_kind'), _('col_exception'), _('col_state'), _('col_build'), _('col_symbol')))
    print('-' * 118)
    for row in rows:
        print('%-19s %-7s %-11s %-26s %-6s %s' % (
            (row['date'] or '')[:18], row['kind'], row['exception'], (row['state'] or '')[:25],
            _('match') if row['buildMatch'] else _('other'), row['symbol']))
    for line in signature_lines(rows):
        print(line)
    print()
    print(col(_('sum_note'), 'dim'))

def build_parser():
    parser = argparse.ArgumentParser(
        prog='crash_triage.py',
        description=_('cli_desc'),
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=_('cli_epilog'))
    parser.add_argument('--crash', '-c', metavar='REPORT', help=_('help_crash'))
    parser.add_argument('--map', '-m', metavar='MAP', help=_('help_map'))
    parser.add_argument('--all', action='store_true', help=_('help_all'))
    parser.add_argument('--pick', action='store_true', help=_('help_pick'))
    parser.add_argument('--summary', action='store_true', help=_('help_summary'))
    parser.add_argument('--json', action='store_true', help=_('help_json'))
    parser.add_argument('--keep-map', action='store_true', help=_('help_keep_map'))
    parser.add_argument('--clean', action='store_true', help=_('help_clean'))
    parser.add_argument('--keep', type=int, default=20, metavar='N', help=_('help_keep'))
    parser.add_argument('--prune-maps', type=int, default=0, metavar='N', help=_('help_prune_maps'))
    parser.add_argument('--dry-run', action='store_true', help=_('help_dry_run'))
    parser.add_argument('--frames', type=int, default=8, metavar='N', help=_('help_frames'))
    parser.add_argument('--crash-dir', metavar='DIR', help=_('help_crash_dir'))
    parser.add_argument('--exe', metavar='EXE', help=_('help_exe'))
    parser.add_argument('--tui', action='store_true', help=_('help_tui'))
    parser.add_argument('--no-gui', action='store_true', help=_('help_no_gui'))
    parser.add_argument('--no-write', action='store_true', help=_('help_no_write'))
    parser.add_argument('--no-color', action='store_true', help=_('help_no_color'))
    parser.add_argument('--lang', choices=['en', 'zh'], help=_('help_lang'))
    return parser

def main(argv=None):
    global USE_COLOR, CURRENT_LANG
    args = build_parser().parse_args(argv)
    
    if args.lang:
        CURRENT_LANG = args.lang
    if args.no_color:
        USE_COLOR = False

    crash_dir = args.crash_dir or DEFAULT_CRASH_DIR
    exe_path = args.exe or DEFAULT_EXE
    current = exe_fingerprint(exe_path)

    if args.keep_map:
        enable_ansi()
        try:
            result = keep_map(args.map, crash_dir, exe_path)
        except Exception as exc:
            print(col('ERROR: %s' % exc, 'red'))
            return 2
        if result['skipped']:
            print(col(_('already_snapshotted', v=result['path']), 'green'))
        else:
            print(col(_('snapshotted', v=result['path']), 'green'))
            print('fingerprint %s   %d B   sha256=%s' % (result['fingerprint'], result['bytes'], result['sha256']))
        return 0

    if args.clean:
        enable_ansi()
        moved = clean(crash_dir, keep=args.keep, prune_maps=args.prune_maps, dry_run=args.dry_run)
        verb = _('archive_would_move', v=len(moved)) if args.dry_run else _('archive_moved', v=len(moved))
        print(col(verb, 'green'))
        for item in moved[:20]:
            print('  ' + item)
        if len(moved) > 20:
            print(_('and_more', v=(len(moved) - 20)))
        return 0

    if args.summary:
        enable_ansi()
        info = select_map(None, args.map, current, crash_dir, DEFAULT_MAP)
        map_data = None
        if info:
            print(col(_('loading_map', v=os.path.basename(info['path'])), 'dim'))
            map_data = read_map(info['path'])
        rows = summary_rows(crash_dir, current, map_data)
        if args.json:
            print(json.dumps(rows, indent=2))
            return 0
        print_summary(crash_dir, current, map_data, rows, info)
        return 0

    if args.crash or args.all or args.pick:
        enable_ansi()
        if args.crash:
            if not os.path.isfile(args.crash):
                print(col(_('err_report_not_found', v=args.crash), 'red'))
                return 2
            targets = [os.path.abspath(args.crash)]
        elif args.pick:
            picked = pick_file(_('gui_choose_report_title'), [(_('gui_crash_reports'), '*.txt'), (_('gui_all_files'), '*.*')], crash_dir)
            if not picked:
                print(col(_('err_nothing_picked'), 'yellow'))
                return 2
            targets = [picked]
        else:
            targets = list(reversed(report_files(crash_dir)))
        if not targets:
            print(_('err_no_reports', v=crash_dir))
            return 2
        stale = 0
        cache = {}
        for i, path in enumerate(targets):
            print(ruler('%s %d/%d   %s' % (_('tui_title'), i + 1, len(targets), os.path.basename(path))))
            result = analyze(path, args.map, current, crash_dir, frames=args.frames, map_cache=cache,
                             default_map=DEFAULT_MAP, write=(not args.no_write and len(targets) == 1))
            for line in step_lines(result['steps']):
                print(line)
            print()
            for line in result['block']:
                print(line)
            if result['stale']:
                stale += 1
        return 1 if stale else 0

    interactive_terminal = False
    try:
        interactive_terminal = bool(sys.stdin and sys.stdin.isatty() and sys.stdout and sys.stdout.isatty())
    except Exception:
        interactive_terminal = False
    if args.tui or args.no_gui or not gui_available() or not interactive_terminal:
        return run_tui(crash_dir, exe_path, DEFAULT_MAP, forced_map=args.map, frames=args.frames)
    return run_gui(crash_dir, exe_path, DEFAULT_MAP, forced_map=args.map, frames=args.frames)

if __name__ == '__main__':
    sys.exit(main())