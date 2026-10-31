using System;
using System.Collections.Generic;
using System.Globalization;

namespace SeiunChartPack
{
    internal static class Lang
    {
        public static string Mode = "auto"; // auto | zh | en
        public static string Code = "zh";    // zh | en

        private static readonly Dictionary<string, string> Zh = new Dictionary<string, string>(StringComparer.Ordinal)
        {
            { "app.title", "Seiun ChartPack" },
            { "header.subtitle", "FNF 超长谱面压缩 · 流式解析 · ZIP 直读" },

            { "lang.auto", "跟随系统" },
            { "lang.zh", "简体中文" },
            { "lang.en", "English" },

            { "input.title", "输入与输出" },
            { "input.label", "输入" },
            { "input.output", "输出" },
            { "input.browse", "浏览…" },
            { "input.chooseJson", "选择 JSON…" },
            { "input.saveAs", "保存为…" },
            { "input.type", "类型" },
            { "input.type.file", "单个 JSON 文件" },
            { "input.type.dir", "文件夹（多个 JSON）" },
            { "input.type.zip", "ZIP 压缩包" },
            { "input.hint", "也可以把 JSON / 文件夹 / ZIP 直接拖进窗口" },
            { "input.dialog.folder", "选择包含谱面 JSON 的文件夹" },
            { "input.dialog.zip", "选择 ZIP 压缩包" },
            { "input.dialog.json", "选择谱面 JSON" },
            { "input.filter.json", "谱面 JSON|*.json|所有文件|*.*" },
            { "input.filter.zip", "ZIP 压缩包|*.zip|所有文件|*.*" },
            { "input.filter.chartpack", "chartpack|*.chartpack|所有文件|*.*" },
            { "input.saveTitle", "保存 chartpack" },
            { "input.outputFolder", "选择输出文件夹" },

            { "opt.mode", "时间模式" },
            { "opt.mode.auto", "自动（推荐）" },
            { "opt.jobs", "并发" },
            { "opt.force", "覆盖已有 pack" },
            { "opt.replace", "打包后删除源 JSON" },

            { "btn.start", "开始打包" },
            { "btn.running", "打包中…" },
            { "btn.stop", "停止" },
            { "btn.clear", "清空" },

            { "link.outputDir", "打开输出目录" },

            { "progress.title", "实时进度" },
            { "progress.waiting", "等待开始…" },
            { "progress.preparing", "准备开始…" },
            { "progress.starting", "启动 Node.js…" },
            { "progress.none", "没有可打包的文件" },
            { "progress.allDone", "全部完成 · {0} / {1} 个文件" },
            { "progress.zero", "0%" },
            { "progress.zeroBytes", "0 B / 0 B" },

            { "stat.input", "总输入" },
            { "stat.output", "总输出" },
            { "stat.ratio", "压缩比" },
            { "stat.time", "总用时" },
            { "stat.speed", "平均速度" },

            { "status.ready", "就绪" },
            { "status.running", "运行中…" },
            { "status.runningCount", "运行中 · {0} / {1}" },
            { "status.runningFail", "运行中 · {0} / {1} · 失败 {2}" },
            { "status.done", "完成 · {0} 个文件 · 失败 0" },
            { "status.doneFail", "完成 · {0} 个失败" },
            { "status.stopped", "已停止" },
            { "status.failedExit", "失败（退出码 {0}）" },
            { "status.finished", "完成" },
            { "status.startFailed", "启动失败" },
            { "status.nodeMissing", "未检测到 Node.js（点击开始会提示安装）" },
            { "status.nodeBad", "Node.js 无法启动" },
            { "status.nodeInfo", "Node.js {0} · {1} 线程" },
            { "status.noFiles", "没有可打包的文件" },

            { "grid.title", "文件明细" },
            { "grid.status", "状态" },
            { "grid.name", "文件" },
            { "grid.input", "原始" },
            { "grid.output", "输出" },
            { "grid.ratio", "压缩比" },
            { "grid.time", "用时" },
            { "grid.speed", "速度" },
            { "grid.notes", "音符" },
            { "grid.groups", "分组" },
            { "grid.mode", "模式" },
            { "grid.processing", "处理中" },
            { "grid.done", "完成" },
            { "grid.failed", "失败" },

            { "log.title", "日志" },
            { "log.clear", "清空" },
            { "log.selected", "已选择: {0}" },
            { "log.node", "Node.js {0}  ·  {1}  ·  {2} 并发" },
            { "log.input", "输入: {0}" },
            { "log.output", "输出: {0}" },
            { "log.plan", "计划: {0} 个文件 / {1}{2}" },
            { "log.planSkipped", " / 跳过 {0}" },
            { "log.done", "完成：{0} → {1}，{2}，{3}" },
            { "log.stopping", "正在停止…" },
            { "log.stopped", "已停止。" },
            { "log.exit", "Node.js 退出码 {0}" },
            { "log.startFailed", "无法启动 Node.js: {0}" },
            { "log.progressParse", "进度解析失败: {0}" },
            { "log.fileDone", "✓ {0}  {1} → {2}  ({3})  {4}  {5}" },
            { "log.fileError", "✗ {0}: {1}" },
            { "log.language", "界面语言：{0}" },
            { "log.nodeKind.file", "单文件" },
            { "log.nodeKind.dir", "文件夹" },
            { "log.nodeKind.zip", "ZIP 直读" },

            { "dlg.inputInvalid.title", "输入无效" },
            { "dlg.inputInvalid.msg", "请选择一个存在的 JSON 文件、文件夹或 ZIP 压缩包。" },
            { "dlg.typeMismatch.title", "类型不匹配" },
            { "dlg.typeMismatch.msg", "输入路径与所选类型（{0}）不匹配。\n\n请改选正确的“类型”，或换一个输入。" },
            { "dlg.outputInvalid.title", "路径错误" },
            { "dlg.outputInvalid.msg", "输出路径无效：{0}" },
            { "dlg.scriptMissing.title", "缺少打包脚本" },
            { "dlg.scriptMissing.msg", "内置 chartpack.mjs 资源丢失，请重新下载完整 exe。" },
            { "dlg.confirmReplace.title", "确认删除源 JSON" },
            { "dlg.confirmReplace.msg", "打包成功后会把源 JSON 删除（只保留 .chartpack）。\n\n确定继续吗？" },
            { "dlg.node.title", "需要 Node.js" },
            { "dlg.node.notFound", "未找到 Node.js" },
            { "dlg.node.tooOld", "Node.js 版本过低" },
            { "dlg.node.msgNotFound", "chartpack 的核心由 Node.js 驱动。请安装 Node.js 18 或更高版本（LTS 即可），安装后回到本程序再点“开始打包”。\r\n\r\n如果已经有绿色版 node.exe，也可以直接选择它。" },
            { "dlg.node.msgTooOld", "当前找到的 Node.js 是 {0}，需要 18 或更高版本。\r\n\r\n请升级 Node.js，或者选择另一个 node.exe。" },
            { "dlg.node.download", "打开 Node.js 下载页" },
            { "dlg.node.choose", "选择 node.exe…" },
            { "dlg.node.cancel", "取消" },
            { "dlg.node.invalidTitle", "Node.js 无效" },
            { "dlg.node.invalidMsg", "这个文件不是可用的 Node.js（需要 18+）。" },
            { "dlg.node.pickTitle", "选择 node.exe" },
            { "dlg.node.filter", "node.exe|node.exe|可执行文件|*.exe" },
            { "dlg.error", "错误" },
            { "dlg.warning", "警告" }
        };

        private static readonly Dictionary<string, string> En = new Dictionary<string, string>(StringComparer.Ordinal)
        {
            { "app.title", "Seiun ChartPack" },
            { "header.subtitle", "FNF chart compression · streaming parser · direct ZIP" },

            { "lang.auto", "Auto" },
            { "lang.zh", "简体中文" },
            { "lang.en", "English" },

            { "input.title", "Input & output" },
            { "input.label", "Input" },
            { "input.output", "Output" },
            { "input.browse", "Browse…" },
            { "input.chooseJson", "Choose JSON…" },
            { "input.saveAs", "Save as…" },
            { "input.type", "Type" },
            { "input.type.file", "Single JSON file" },
            { "input.type.dir", "Folder (multiple JSONs)" },
            { "input.type.zip", "ZIP archive" },
            { "input.hint", "Drag a JSON, folder or ZIP here" },
            { "input.dialog.folder", "Choose a folder containing chart JSON files" },
            { "input.dialog.zip", "Choose a ZIP archive" },
            { "input.dialog.json", "Choose a chart JSON" },
            { "input.filter.json", "Chart JSON|*.json|All files|*.*" },
            { "input.filter.zip", "ZIP archive|*.zip|All files|*.*" },
            { "input.filter.chartpack", "chartpack|*.chartpack|All files|*.*" },
            { "input.saveTitle", "Save chartpack" },
            { "input.outputFolder", "Choose output folder" },

            { "opt.mode", "Time mode" },
            { "opt.mode.auto", "Auto (recommended)" },
            { "opt.jobs", "Workers" },
            { "opt.force", "Overwrite existing packs" },
            { "opt.replace", "Delete source JSON after packing" },

            { "btn.start", "Start" },
            { "btn.running", "Packing…" },
            { "btn.stop", "Stop" },
            { "btn.clear", "Clear" },

            { "link.outputDir", "Open output folder" },

            { "progress.title", "Progress" },
            { "progress.waiting", "Waiting to start…" },
            { "progress.preparing", "Preparing…" },
            { "progress.starting", "Starting Node.js…" },
            { "progress.none", "Nothing to pack" },
            { "progress.allDone", "All done · {0} / {1} files" },
            { "progress.zero", "0%" },
            { "progress.zeroBytes", "0 B / 0 B" },

            { "stat.input", "Total input" },
            { "stat.output", "Total output" },
            { "stat.ratio", "Ratio" },
            { "stat.time", "Elapsed" },
            { "stat.speed", "Avg speed" },

            { "status.ready", "Ready" },
            { "status.running", "Running…" },
            { "status.runningCount", "Running · {0} / {1}" },
            { "status.runningFail", "Running · {0} / {1} · failed {2}" },
            { "status.done", "Done · {0} files · 0 failed" },
            { "status.doneFail", "Done · {0} failed" },
            { "status.stopped", "Stopped" },
            { "status.failedExit", "Failed (exit code {0})" },
            { "status.finished", "Finished" },
            { "status.startFailed", "Start failed" },
            { "status.nodeMissing", "Node.js not found (click Start for setup)" },
            { "status.nodeBad", "Node.js failed to start" },
            { "status.nodeInfo", "Node.js {0} · {1} threads" },
            { "status.noFiles", "Nothing to pack" },

            { "grid.title", "Files" },
            { "grid.status", "Status" },
            { "grid.name", "File" },
            { "grid.input", "Input" },
            { "grid.output", "Output" },
            { "grid.ratio", "Ratio" },
            { "grid.time", "Time" },
            { "grid.speed", "Speed" },
            { "grid.notes", "Notes" },
            { "grid.groups", "Groups" },
            { "grid.mode", "Mode" },
            { "grid.processing", "Working" },
            { "grid.done", "Done" },
            { "grid.failed", "Failed" },

            { "log.title", "Log" },
            { "log.clear", "Clear" },
            { "log.selected", "Selected: {0}" },
            { "log.node", "Node.js {0}  ·  {1}  ·  {2} workers" },
            { "log.input", "Input: {0}" },
            { "log.output", "Output: {0}" },
            { "log.plan", "Plan: {0} files / {1}{2}" },
            { "log.planSkipped", " / skipped {0}" },
            { "log.done", "Done: {0} → {1}, {2}, {3}" },
            { "log.stopping", "Stopping…" },
            { "log.stopped", "Stopped." },
            { "log.exit", "Node.js exit code {0}" },
            { "log.startFailed", "Could not start Node.js: {0}" },
            { "log.progressParse", "Progress parse error: {0}" },
            { "log.fileDone", "✓ {0}  {1} → {2}  ({3})  {4}  {5}" },
            { "log.fileError", "✗ {0}: {1}" },
            { "log.language", "UI language: {0}" },
            { "log.nodeKind.file", "single file" },
            { "log.nodeKind.dir", "folder" },
            { "log.nodeKind.zip", "direct ZIP" },

            { "dlg.inputInvalid.title", "Invalid input" },
            { "dlg.inputInvalid.msg", "Choose an existing JSON file, folder, or ZIP archive." },
            { "dlg.typeMismatch.title", "Type mismatch" },
            { "dlg.typeMismatch.msg", "The input path does not match the selected type ({0}).\n\nPick the matching type, or choose another input." },
            { "dlg.outputInvalid.title", "Path error" },
            { "dlg.outputInvalid.msg", "Invalid output path: {0}" },
            { "dlg.scriptMissing.title", "Missing packer script" },
            { "dlg.scriptMissing.msg", "Embedded chartpack.mjs is missing; please download the complete exe again." },
            { "dlg.confirmReplace.title", "Delete source JSON?" },
            { "dlg.confirmReplace.msg", "Source JSON files will be deleted after a successful pack (only .chartpack remains).\n\nContinue?" },
            { "dlg.node.title", "Node.js required" },
            { "dlg.node.notFound", "Node.js not found" },
            { "dlg.node.tooOld", "Node.js is too old" },
            { "dlg.node.msgNotFound", "chartpack is powered by Node.js. Install Node.js 18+ (LTS is fine), then return here and press Start.\r\n\r\nIf you already have a portable node.exe, choose it directly." },
            { "dlg.node.msgTooOld", "Found Node.js {0}; version 18 or newer is required.\r\n\r\nUpgrade Node.js or choose another node.exe." },
            { "dlg.node.download", "Open Node.js download page" },
            { "dlg.node.choose", "Choose node.exe…" },
            { "dlg.node.cancel", "Cancel" },
            { "dlg.node.invalidTitle", "Invalid Node.js" },
            { "dlg.node.invalidMsg", "This file is not a usable Node.js (18+ required)." },
            { "dlg.node.pickTitle", "Choose node.exe" },
            { "dlg.node.filter", "node.exe|node.exe|Executables|*.exe" },
            { "dlg.error", "Error" },
            { "dlg.warning", "Warning" }
        };

        public static void SetMode(string mode)
        {
            if (mode == "zh" || mode == "en" || mode == "auto") Mode = mode;
            else Mode = "auto";
            if (Mode == "auto")
            {
                CultureInfo c = CultureInfo.CurrentUICulture;
                Code = (c != null && c.TwoLetterISOLanguageName == "zh") ? "zh" : "en";
            }
            else Code = Mode;
        }

        public static string T(string key)
        {
            if (key == null) return "";
            Dictionary<string, string> d = (Code == "en") ? En : Zh;
            string v;
            if (d.TryGetValue(key, out v)) return v;
            if (Zh.TryGetValue(key, out v)) return v;
            return key;
        }

        public static string F(string key, params object[] args)
        {
            return string.Format(CultureInfo.InvariantCulture, T(key), args);
        }

        public static string DisplayName
        {
            get { return Code == "zh" ? "简体中文" : "English"; }
        }
    }
}
