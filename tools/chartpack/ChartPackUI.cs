using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Globalization;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;

[assembly: AssemblyTitle("Seiun ChartPack")]
[assembly: AssemblyDescription("FNF chartpack GUI - streaming chart compressor")]
[assembly: AssemblyProduct("Seiun ChartPack")]
[assembly: AssemblyCompany("Seiun")]
[assembly: AssemblyVersion("2.0.0.0")]
[assembly: AssemblyFileVersion("2.0.0.0")]

namespace SeiunChartPack
{
    internal static class Theme
    {
        public static readonly Color Bg = Color.FromArgb(246, 248, 252);
        public static readonly Color Card = Color.White;
        public static readonly Color Border = Color.FromArgb(226, 232, 240);
        public static readonly Color Text = Color.FromArgb(15, 23, 42);
        public static readonly Color Muted = Color.FromArgb(100, 116, 139);
        public static readonly Color Faint = Color.FromArgb(148, 163, 184);
        public static readonly Color Accent = Color.FromArgb(37, 99, 235);
        public static readonly Color AccentDark = Color.FromArgb(29, 78, 216);
        public static readonly Color Green = Color.FromArgb(22, 163, 74);
        public static readonly Color Red = Color.FromArgb(220, 38, 38);
        public static readonly Color SoftBlue = Color.FromArgb(239, 246, 255);
        public static readonly Color SoftGray = Color.FromArgb(241, 245, 249);

        public static Font F(float size, bool bold)
        {
            return new Font("Microsoft YaHei UI", size, bold ? FontStyle.Bold : FontStyle.Regular, GraphicsUnit.Point);
        }
    }

    internal static class Ui
    {
        public static GraphicsPath Rounded(Rectangle r, int radius)
        {
            int d = Math.Max(1, radius * 2);
            GraphicsPath p = new GraphicsPath();
            if (radius <= 0) { p.AddRectangle(r); return p; }
            p.AddArc(r.X, r.Y, d, d, 180, 90);
            p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
            p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
            p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
            p.CloseFigure();
            return p;
        }

        public static string Bytes(long n)
        {
            double v = n;
            string[] units = new string[] { "B", "KiB", "MiB", "GiB", "TiB" };
            int u = 0;
            while (v >= 1024 && u < units.Length - 1) { v /= 1024; u++; }
            if (u == 0) return n.ToString("N0", CultureInfo.InvariantCulture) + " B";
            return v.ToString(v >= 100 ? "0" : v >= 10 ? "0.0" : "0.00", CultureInfo.InvariantCulture) + " " + units[u];
        }

        public static string Speed(double mbps)
        {
            if (mbps >= 1024) return (mbps / 1024.0).ToString("0.00", CultureInfo.InvariantCulture) + " GB/s";
            if (mbps >= 10) return mbps.ToString("0", CultureInfo.InvariantCulture) + " MB/s";
            return mbps.ToString("0.0", CultureInfo.InvariantCulture) + " MB/s";
        }

        public static string Ratio(double r)
        {
            if (r <= 0) return "—";
            if (r >= 1000000) return r.ToString("N0", CultureInfo.InvariantCulture) + "×";
            if (r >= 1000) return r.ToString("N0", CultureInfo.InvariantCulture) + "×";
            if (r >= 10) return r.ToString("0.0", CultureInfo.InvariantCulture) + "×";
            return r.ToString("0.00", CultureInfo.InvariantCulture) + "×";
        }

        public static string Duration(double ms)
        {
            if (ms < 1000) return ms.ToString("0", CultureInfo.InvariantCulture) + " ms";
            double s = ms / 1000.0;
            if (s < 60) return s.ToString("0.00", CultureInfo.InvariantCulture) + " s";
            int m = (int)(s / 60);
            double rest = s - m * 60;
            return m.ToString(CultureInfo.InvariantCulture) + " m " + rest.ToString("00.0", CultureInfo.InvariantCulture) + " s";
        }

        public static string Count(long n)
        {
            return n.ToString("N0", CultureInfo.InvariantCulture);
        }

        public static string GetStr(Dictionary<string, object> d, string key, string def)
        {
            if (d == null || !d.ContainsKey(key) || d[key] == null) return def;
            return Convert.ToString(d[key], CultureInfo.InvariantCulture);
        }

        public static long GetLong(Dictionary<string, object> d, string key, long def)
        {
            if (d == null || !d.ContainsKey(key) || d[key] == null) return def;
            try { return Convert.ToInt64(d[key], CultureInfo.InvariantCulture); }
            catch { return def; }
        }

        public static double GetDouble(Dictionary<string, object> d, string key, double def)
        {
            if (d == null || !d.ContainsKey(key) || d[key] == null) return def;
            try { return Convert.ToDouble(d[key], CultureInfo.InvariantCulture); }
            catch { return def; }
        }

        public static int GetInt(Dictionary<string, object> d, string key, int def)
        {
            return (int)GetLong(d, key, def);
        }

        public static bool GetBool(Dictionary<string, object> d, string key, bool def)
        {
            if (d == null || !d.ContainsKey(key) || d[key] == null) return def;
            try { return Convert.ToBoolean(d[key], CultureInfo.InvariantCulture); }
            catch { return def; }
        }
    }

    internal class CardPanel : Panel
    {
        public Color FillColor = Theme.Card;
        public Color BorderColor = Theme.Border;
        public int Radius = 12;

        public CardPanel()
        {
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint |
                     ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            BackColor = Theme.Bg;
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            if (Width < 2 || Height < 2) return;
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            float s = DeviceDpi / 96f;
            Rectangle r = new Rectangle(0, 0, Width - 1, Height - 1);
            using (GraphicsPath p = Ui.Rounded(r, (int)Math.Round(Radius * s)))
            {
                using (SolidBrush b = new SolidBrush(FillColor)) e.Graphics.FillPath(b, p);
                using (Pen pen = new Pen(BorderColor, 1f)) e.Graphics.DrawPath(pen, p);
            }
        }
    }

    internal class HeaderPanel : Panel
    {
        public string Title = "Seiun ChartPack";
        public string Subtitle = Lang.T("header.subtitle");
        public string Version = "v2.0";

        public HeaderPanel()
        {
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint |
                     ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            BackColor = Theme.Accent;
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            if (Width < 2 || Height < 2) return;
            Graphics g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            float s = DeviceDpi / 96f;
            using (LinearGradientBrush b = new LinearGradientBrush(ClientRectangle,
                Color.FromArgb(29, 78, 216), Color.FromArgb(59, 130, 246), LinearGradientMode.Horizontal))
            {
                g.FillRectangle(b, ClientRectangle);
            }
            using (SolidBrush soft = new SolidBrush(Color.FromArgb(20, 255, 255, 255)))
            {
                g.FillEllipse(soft, (int)(-90 * s), (int)(-150 * s), (int)(360 * s), (int)(360 * s));
                g.FillEllipse(soft, (int)(Width - 180 * s), (int)(-80 * s), (int)(260 * s), (int)(260 * s));
            }
            int lx = (int)(24 * s), ly = (int)(18 * s), ls = (int)(48 * s);
            using (GraphicsPath p = Ui.Rounded(new Rectangle(lx, ly, ls, ls), (int)(14 * s)))
            {
                using (SolidBrush b = new SolidBrush(Color.FromArgb(38, 255, 255, 255))) g.FillPath(b, p);
                using (Pen pen = new Pen(Color.FromArgb(80, 255, 255, 255), 1f)) g.DrawPath(pen, p);
                using (Font f = Theme.F(15f, true))
                using (SolidBrush b = new SolidBrush(Color.White))
                {
                    StringFormat sf = new StringFormat();
                    sf.Alignment = StringAlignment.Center;
                    sf.LineAlignment = StringAlignment.Center;
                    g.DrawString("CP", f, b, new RectangleF(lx, ly, ls, ls), sf);
                    sf.Dispose();
                }
            }
            int tx = (int)(86 * s);
            using (Font f = Theme.F(19f, true))
            using (SolidBrush b = new SolidBrush(Color.White))
            {
                g.DrawString(Title, f, b, tx, (int)(12 * s));
            }
            using (Font f = Theme.F(10f, false))
            using (SolidBrush b = new SolidBrush(Color.FromArgb(215, 230, 255)))
            {
                g.DrawString(Subtitle, f, b, tx + (int)(1 * s), (int)(48 * s));
            }
            using (Font f = Theme.F(9f, false))
            using (SolidBrush b = new SolidBrush(Color.FromArgb(190, 215, 255)))
            {
                SizeF sz = g.MeasureString(Version, f);
                g.DrawString(Version, f, b, Width - sz.Width - (int)(22 * s), (int)(54 * s));
            }
        }
    }

    internal class FlatButton : Button
    {
        public Color NormalColor = Theme.Accent;
        public Color HoverColor = Theme.AccentDark;
        public Color PressColor = Color.FromArgb(30, 64, 175);
        public Color BorderColor = Color.Transparent;

        public FlatButton()
        {
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint |
                     ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            FlatStyle = FlatStyle.Flat;
            FlatAppearance.BorderSize = 0;
            FlatAppearance.MouseOverBackColor = Color.Transparent;
            FlatAppearance.MouseDownBackColor = Color.Transparent;
            UseVisualStyleBackColor = false;
            Cursor = Cursors.Hand;
            BackColor = NormalColor;
            ForeColor = Color.White;
            Font = Theme.F(9.5f, true);
            TextAlign = ContentAlignment.MiddleCenter;
        }

        protected override void OnMouseEnter(EventArgs e) { base.OnMouseEnter(e); BackColor = HoverColor; }
        protected override void OnMouseLeave(EventArgs e) { base.OnMouseLeave(e); BackColor = NormalColor; }
        protected override void OnMouseDown(MouseEventArgs e) { base.OnMouseDown(e); BackColor = PressColor; }
        protected override void OnMouseUp(MouseEventArgs e) { base.OnMouseUp(e); BackColor = ClientRectangle.Contains(PointToClient(Cursor.Position)) ? HoverColor : NormalColor; }

        protected override void OnResize(EventArgs e)
        {
            base.OnResize(e);
            if (Width <= 0 || Height <= 0) return;
            using (GraphicsPath p = Ui.Rounded(new Rectangle(0, 0, Width, Height), Math.Min(10, Height / 2)))
            {
                Region old = Region;
                Region = new Region(p);
                if (old != null) old.Dispose();
            }
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            Rectangle r = new Rectangle(0, 0, Width - 1, Height - 1);
            using (GraphicsPath p = Ui.Rounded(r, Math.Min(10, Height / 2)))
            {
                using (SolidBrush b = new SolidBrush(BackColor)) e.Graphics.FillPath(b, p);
                if (BorderColor != Color.Transparent)
                    using (Pen pen = new Pen(BorderColor, 1f)) e.Graphics.DrawPath(pen, p);
            }
            TextRenderer.DrawText(e.Graphics, Text, Font, r, ForeColor,
                TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis);
        }
    }

    internal class SegmentedButton : RadioButton
    {
        public SegmentedButton()
        {
            Appearance = Appearance.Button;
            FlatStyle = FlatStyle.Flat;
            FlatAppearance.BorderSize = 0;
            TextAlign = ContentAlignment.MiddleCenter;
            Cursor = Cursors.Hand;
            Font = Theme.F(9f, false);
            AutoSize = false;
            BackColor = Theme.SoftGray;
            ForeColor = Theme.Muted;
            CheckedChanged += delegate { ApplyStyle(); };
        }

        private void ApplyStyle()
        {
            if (Checked)
            {
                BackColor = Theme.Accent;
                ForeColor = Color.White;
                Font = Theme.F(9f, true);
            }
            else
            {
                BackColor = Theme.SoftGray;
                ForeColor = Theme.Muted;
                Font = Theme.F(9f, false);
            }
        }

        protected override void OnResize(EventArgs e)
        {
            base.OnResize(e);
            if (Width <= 0 || Height <= 0) return;
            using (GraphicsPath p = Ui.Rounded(new Rectangle(0, 0, Width, Height), Math.Min(9, Height / 2)))
            {
                Region old = Region;
                Region = new Region(p);
                if (old != null) old.Dispose();
            }
        }
    }

    internal class SlimProgress : Control
    {
        private int _value;
        private bool _indeterminate;
        private int _phase;
        private System.Windows.Forms.Timer _timer;

        public Color BarColor = Theme.Accent;

        public SlimProgress()
        {
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint |
                     ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            Height = 10;
            BackColor = Color.White;
            _timer = new System.Windows.Forms.Timer();
            _timer.Interval = 16;
            _timer.Tick += delegate { if (_indeterminate) { _phase += 8; Invalidate(); } };
            _timer.Start();
        }

        public int Value
        {
            get { return _value; }
            set
            {
                int v = value;
                if (v < 0) v = 0;
                if (v > 1000) v = 1000;
                if (_value != v) { _value = v; Invalidate(); }
            }
        }

        public bool Indeterminate
        {
            get { return _indeterminate; }
            set { if (_indeterminate != value) { _indeterminate = value; _phase = 0; Invalidate(); } }
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing && _timer != null) { _timer.Dispose(); _timer = null; }
            base.Dispose(disposing);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            if (Width < 2 || Height < 2) return;
            Graphics g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            int h = Math.Max(4, Height);
            Rectangle back = new Rectangle(0, 0, Width, h);
            using (GraphicsPath p = Ui.Rounded(back, h / 2))
            using (SolidBrush b = new SolidBrush(Color.FromArgb(232, 238, 248))) g.FillPath(b, p);

            if (Width <= 2) return;
            Rectangle clip = new Rectangle(1, 1, Width - 2, h - 2);
            using (GraphicsPath cp = Ui.Rounded(clip, (h - 2) / 2))
            {
                Region old = g.Clip;
                g.SetClip(cp);
                if (_indeterminate)
                {
                    int seg = Math.Max(60, Width / 4);
                    int x = (_phase % (Width + seg)) - seg;
                    using (SolidBrush b = new SolidBrush(BarColor)) g.FillRectangle(b, x, 1, seg, h - 2);
                }
                else
                {
                    int w = (int)Math.Round((Width - 2) * (_value / 1000.0));
                    if (w > 0)
                        using (SolidBrush b = new SolidBrush(BarColor)) g.FillRectangle(b, 1, 1, w, h - 2);
                }
                g.Clip = old;
            }
        }
    }

    internal static class AppSettings
    {
        private static string dir;
        private static string file;
        private static Dictionary<string, string> map;

        static AppSettings()
        {
            dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "SeiunChartPack");
            file = Path.Combine(dir, "settings.ini");
            map = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            try
            {
                if (File.Exists(file))
                {
                    foreach (string raw in File.ReadAllLines(file, Encoding.UTF8))
                    {
                        string line = raw.Trim();
                        if (line.Length == 0 || line.StartsWith("#")) continue;
                        int eq = line.IndexOf('=');
                        if (eq <= 0) continue;
                        map[line.Substring(0, eq).Trim()] = line.Substring(eq + 1).Trim();
                    }
                }
            }
            catch { }
        }

        public static string Get(string key, string def)
        {
            string v;
            if (map.TryGetValue(key, out v)) return v;
            return def;
        }

        public static int GetInt(string key, int def)
        {
            int v;
            if (int.TryParse(Get(key, ""), out v)) return v;
            return def;
        }

        public static void Set(string key, string value)
        {
            map[key] = value;
        }

        public static void Save()
        {
            try
            {
                Directory.CreateDirectory(dir);
                StringBuilder sb = new StringBuilder();
                foreach (KeyValuePair<string, string> kv in map)
                    sb.AppendLine(kv.Key + "=" + kv.Value);
                File.WriteAllText(file, sb.ToString(), Encoding.UTF8);
            }
            catch { }
        }
    }

    internal static class AppPaths
    {
        public static string Dir
        {
            get { return Path.GetDirectoryName(Application.ExecutablePath); }
        }

        public static string LocalDataDir
        {
            get
            {
                string d = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SeiunChartPack");
                Directory.CreateDirectory(d);
                return d;
            }
        }
    }

    internal static class ScriptProvider
    {
        public static string GetScriptPath()
        {
            string local = Path.Combine(AppPaths.Dir, "chartpack.mjs");
            if (File.Exists(local)) return local;

            Stream s = Assembly.GetExecutingAssembly().GetManifestResourceStream("chartpack.mjs");
            if (s == null) throw new Exception(Lang.T("dlg.scriptMissing.msg"));
            byte[] data;
            using (s)
            using (MemoryStream ms = new MemoryStream())
            {
                byte[] buf = new byte[81920];
                int n;
                while ((n = s.Read(buf, 0, buf.Length)) > 0) ms.Write(buf, 0, n);
                data = ms.ToArray();
            }
            string hash;
            using (SHA256 sha = SHA256.Create())
            {
                byte[] h = sha.ComputeHash(data);
                StringBuilder sb = new StringBuilder();
                for (int i = 0; i < 8; i++) sb.Append(h[i].ToString("x2"));
                hash = sb.ToString();
            }
            string target = Path.Combine(AppPaths.LocalDataDir, "chartpack-" + hash + ".mjs");
            if (!File.Exists(target))
            {
                string tmp = target + ".tmp";
                File.WriteAllBytes(tmp, data);
                if (File.Exists(target)) File.Delete(target);
                File.Move(tmp, target);
            }
            return target;
        }
    }

    internal static class NodeLocator
    {
        public static string Find()
        {
            string local = Path.Combine(AppPaths.Dir, "node.exe");
            if (File.Exists(local)) return local;

            string saved = AppSettings.Get("node", "");
            if (saved.Length > 0 && File.Exists(saved)) return saved;

            string[] common = new string[]
            {
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "nodejs", "node.exe"),
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86), "nodejs", "node.exe"),
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", "nodejs", "node.exe")
            };
            foreach (string p in common)
            {
                try { if (File.Exists(p)) return p; } catch { }
            }

            string pathEnv = Environment.GetEnvironmentVariable("PATH");
            if (pathEnv != null)
            {
                foreach (string raw in pathEnv.Split(new char[] { ';' }, StringSplitOptions.RemoveEmptyEntries))
                {
                    try
                    {
                        string p = Path.Combine(raw.Trim().Trim('"'), "node.exe");
                        if (File.Exists(p)) return p;
                    }
                    catch { }
                }
            }
            return null;
        }

        public static string GetVersion(string node)
        {
            try
            {
                ProcessStartInfo psi = new ProcessStartInfo();
                psi.FileName = node;
                psi.Arguments = "--version";
                psi.UseShellExecute = false;
                psi.CreateNoWindow = true;
                psi.RedirectStandardOutput = true;
                psi.RedirectStandardError = true;
                using (Process p = Process.Start(psi))
                {
                    string output = p.StandardOutput.ReadToEnd().Trim();
                    p.WaitForExit(5000);
                    return output;
                }
            }
            catch { return ""; }
        }

        public static bool IsSupported(string node, out string version)
        {
            version = GetVersion(node);
            if (version.Length == 0) return false;
            string v = version.TrimStart('v', 'V');
            int dot = v.IndexOf('.');
            int major;
            if (dot > 0 && int.TryParse(v.Substring(0, dot), out major)) return major >= 18;
            return false;
        }
    }

    internal static class Commands
    {
        public static string Quote(string s)
        {
            if (s == null) s = "";
            return "\"" + s.Replace("\"", "\\\"") + "\"";
        }

        public static string Build(string mode, string input, string output, int jobs, string timeMode, bool force, bool replace)
        {
            if (mode == "file")
                return "pack " + Quote(input) + " " + Quote(output)
                    + " --time-mode=" + timeMode + " --progress-json";
            if (mode == "dir")
                return "pack-dir " + Quote(input) + " --out-dir=" + Quote(output)
                    + " --jobs=" + jobs + " --time-mode=" + timeMode
                    + (force ? " --force" : "") + (replace ? " --replace" : "") + " --progress-json";
            return "pack-zip " + Quote(input) + " --out-dir=" + Quote(output)
                + " --jobs=" + jobs + " --time-mode=" + timeMode
                + (force ? " --force" : "") + " --progress-json";
        }
    }

    internal class PackRunner : IDisposable
    {
        private Process proc;
        private bool disposed;
        private ManualResetEvent outputDone;

        public event Action<Dictionary<string, object>> EventReceived;
        public event Action<string, bool> LogReceived;
        public event Action<int> ProcessExited;

        public bool Running
        {
            get { return proc != null && !proc.HasExited; }
        }

        public PackRunner()
        {
            outputDone = new ManualResetEvent(false);
        }

        public void Start(string node, string script, string args)
        {
            outputDone.Reset();
            ProcessStartInfo psi = new ProcessStartInfo();
            psi.FileName = node;
            psi.Arguments = Commands.Quote(script) + " " + args;
            psi.WorkingDirectory = Path.GetDirectoryName(script);
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.WindowStyle = ProcessWindowStyle.Hidden;
            psi.RedirectStandardOutput = true;
            psi.RedirectStandardError = true;
            psi.StandardOutputEncoding = Encoding.UTF8;
            psi.StandardErrorEncoding = Encoding.UTF8;

            proc = new Process();
            proc.StartInfo = psi;
            proc.EnableRaisingEvents = true;
            proc.OutputDataReceived += OnOutput;
            proc.ErrorDataReceived += OnError;
            proc.Exited += OnExited;
            proc.Start();
            proc.BeginOutputReadLine();
            proc.BeginErrorReadLine();
        }

        private void OnOutput(object sender, DataReceivedEventArgs e)
        {
            if (e.Data == null) { outputDone.Set(); return; }
            string line = e.Data;
            if (line.StartsWith("@@CP@@"))
            {
                try
                {
                    JavaScriptSerializer ser = new JavaScriptSerializer();
                    ser.MaxJsonLength = int.MaxValue;
                    Dictionary<string, object> d = ser.Deserialize<Dictionary<string, object>>(line.Substring(6));
                    if (EventReceived != null) EventReceived(d);
                }
                catch (Exception ex)
                {
                    if (LogReceived != null) LogReceived(Lang.F("log.progressParse", ex.Message), true);
                }
            }
            else if (line.StartsWith("FAIL") || line.StartsWith("skip (exists)") || line.StartsWith("usage:"))
            {
                if (LogReceived != null) LogReceived(line, false);
            }
        }

        private void OnError(object sender, DataReceivedEventArgs e)
        {
            if (e.Data != null && LogReceived != null) LogReceived(e.Data, true);
        }

        private void OnExited(object sender, EventArgs e)
        {
            // The process can exit before the last stdout lines are dispatched.  Wait for the
            // reader to hit EOF so summary/file-done events are never lost on very fast files.
            try { outputDone.WaitOne(3000); } catch { }
            int code = 0;
            try { code = proc.ExitCode; } catch { }
            if (ProcessExited != null) ProcessExited(code);
        }

        public void Stop()
        {
            try { if (Running) proc.Kill(); } catch { }
        }

        public void Dispose()
        {
            if (disposed) return;
            disposed = true;
            try { if (proc != null) proc.Dispose(); } catch { }
            proc = null;
            try { if (outputDone != null) outputDone.Close(); } catch { }
            outputDone = null;
        }
    }

    internal class NodeMissingForm : Form
    {
        public string SelectedNode;
        private Label msg;
        private FlatButton btnDownload, btnBrowse, btnCancel;

        public NodeMissingForm(string foundNode, string version)
        {
            Text = Lang.T("dlg.node.title");
            StartPosition = FormStartPosition.CenterParent;
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            MinimizeBox = false;
            ShowInTaskbar = false;
            ClientSize = new Size(560, 300);
            BackColor = Color.White;
            Font = Theme.F(9.5f, false);
            try { Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { }

            Label title = new Label();
            title.Text = foundNode == null ? Lang.T("dlg.node.notFound") : Lang.T("dlg.node.tooOld");
            title.Font = Theme.F(15f, true);
            title.ForeColor = Theme.Text;
            title.AutoSize = false;
            title.SetBounds(26, 22, 500, 34);
            Controls.Add(title);

            msg = new Label();
            msg.AutoSize = false;
            msg.SetBounds(26, 64, 508, 130);
            msg.ForeColor = Theme.Muted;
            msg.Font = Theme.F(9.5f, false);
            if (foundNode == null)
                msg.Text = Lang.T("dlg.node.msgNotFound");
            else
                msg.Text = Lang.F("dlg.node.msgTooOld", version);
            Controls.Add(msg);

            btnDownload = new FlatButton();
            btnDownload.Text = Lang.T("dlg.node.download");
            btnDownload.SetBounds(26, 220, 220, 40);
            Controls.Add(btnDownload);

            btnBrowse = new FlatButton();
            btnBrowse.Text = Lang.T("dlg.node.choose");
            btnBrowse.NormalColor = Theme.SoftGray;
            btnBrowse.HoverColor = Color.FromArgb(226, 232, 240);
            btnBrowse.PressColor = Color.FromArgb(203, 213, 225);
            btnBrowse.BackColor = Theme.SoftGray;
            btnBrowse.ForeColor = Theme.Text;
            btnBrowse.SetBounds(256, 220, 160, 40);
            Controls.Add(btnBrowse);

            btnCancel = new FlatButton();
            btnCancel.Text = Lang.T("dlg.node.cancel");
            btnCancel.NormalColor = Theme.SoftGray;
            btnCancel.HoverColor = Color.FromArgb(226, 232, 240);
            btnCancel.PressColor = Color.FromArgb(203, 213, 225);
            btnCancel.BackColor = Theme.SoftGray;
            btnCancel.ForeColor = Theme.Text;
            btnCancel.SetBounds(426, 220, 110, 40);
            Controls.Add(btnCancel);

            btnDownload.Click += delegate
            {
                try { Process.Start("https://nodejs.org/en/download"); } catch { }
            };
            btnBrowse.Click += delegate { PickNode(); };
            btnCancel.Click += delegate { DialogResult = DialogResult.Cancel; Close(); };
            AcceptButton = btnDownload;
            CancelButton = btnCancel;
        }

        private void PickNode()
        {
            using (OpenFileDialog d = new OpenFileDialog())
            {
                d.Title = Lang.T("dlg.node.pickTitle");
                d.Filter = Lang.T("dlg.node.filter");
                if (d.ShowDialog(this) != DialogResult.OK) return;
                string ver;
                if (!NodeLocator.IsSupported(d.FileName, out ver))
                {
                    MessageBox.Show(this, Lang.T("dlg.node.invalidMsg"), Lang.T("dlg.node.invalidTitle"),
                        MessageBoxButtons.OK, MessageBoxIcon.Warning);
                    return;
                }
                AppSettings.Set("node", d.FileName);
                AppSettings.Save();
                SelectedNode = d.FileName;
                DialogResult = DialogResult.OK;
                Close();
            }
        }
    }

    internal static class NodeHelper
    {
        public static string Ensure(IWin32Window owner, out string version)
        {
            version = "";
            string node = NodeLocator.Find();
            if (node != null && NodeLocator.IsSupported(node, out version)) return node;

            using (NodeMissingForm f = new NodeMissingForm(node, version))
            {
                if (f.ShowDialog(owner) == DialogResult.OK && f.SelectedNode != null)
                {
                    if (NodeLocator.IsSupported(f.SelectedNode, out version)) return f.SelectedNode;
                }
            }
            return null;
        }
    }

    internal class MainForm : Form
    {
        private HeaderPanel header;
        private CardPanel cardInput, cardOptions, cardProgress, cardGrid, cardLog;
        private TextBox txtInput, txtOutput;
        private FlatButton btnBrowseInput, btnBrowseOutput, btnStart, btnStop;
        private ComboBox cmbMode, cmbType, cmbLang;
        private Label lblInputTitle, lblInputLabel, lblOutputLabel, lblTypeLabel, lblHint;
        private Label lblModeLabel, lblJobsLabel, lblProgressTitle, lblGridTitle, lblLogTitle;
        private bool applyingLanguage;
        private NumericUpDown numJobs;
        private CheckBox chkForce, chkReplace;
        private SlimProgress progress;
        private Label lblPercent, lblBytes, lblCurrent, lblStatus, lblNode;
        private Label[] statCaptions, statValues;
        private DataGridView grid;
        private RichTextBox log;
        private LinkLabel lnkOutput, lnkClear;
        private Dictionary<int, DataGridViewRow> rowsByIndex;

        private long totalBytes, doneBytes, totalOut;
        private int totalFiles, doneFiles, failed, skipped;
        private DateTime startedAt;
        private bool running, stopped;
        private PackRunner runner;

        public MainForm()
        {
            Text = "Seiun ChartPack";
            StartPosition = FormStartPosition.CenterScreen;
            AutoScaleMode = AutoScaleMode.None;
            ClientSize = new Size(1140, 980);
            MinimumSize = new Size(1140, 760);
            BackColor = Theme.Bg;
            Font = Theme.F(9.5f, false);
            DoubleBuffered = true;
            AllowDrop = true;
            KeyPreview = true;
            try { Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { }

            rowsByIndex = new Dictionary<int, DataGridViewRow>();

            Lang.SetMode(AppSettings.Get("language", "auto"));
            BuildUi();
            LoadSettings();
            ApplyLanguage();
        }

        private float S { get { return DeviceDpi / 96f; } }
        private int X(float v) { return (int)Math.Round(v * S); }

        private Label MakeLabel(string text, float size, bool bold, Color color)
        {
            Label l = new Label();
            l.Text = text;
            l.AutoSize = false;
            l.UseMnemonic = false;
            l.Font = Theme.F(size, bold);
            l.ForeColor = color;
            l.BackColor = Color.White;
            l.TextAlign = ContentAlignment.MiddleLeft;
            return l;
        }

        private Label MakeI18nLabel(string name, string key, float size, bool bold, Color color)
        {
            Label l = MakeLabel(Lang.T(key), size, bold, color);
            l.Name = name;
            l.Tag = "i18n:" + key;
            return l;
        }

        private FlatButton MakeSecondaryButton()
        {
            FlatButton b = new FlatButton();
            b.NormalColor = Theme.SoftGray;
            b.HoverColor = Color.FromArgb(226, 232, 240);
            b.PressColor = Color.FromArgb(203, 213, 225);
            b.BackColor = Theme.SoftGray;
            b.ForeColor = Theme.Text;
            return b;
        }

        private void SetI18n(Control c, string key)
        {
            c.Text = Lang.T(key);
            c.Tag = "i18n:" + key;
        }

        private void BuildUi()
        {
            header = new HeaderPanel();
            Controls.Add(header);

            cardInput = new CardPanel();
            Controls.Add(cardInput);
            lblInputTitle = MakeI18nLabel("lblInputTitle", "input.title", 11f, true, Theme.Text);
            cardInput.Controls.Add(lblInputTitle);
            lblInputLabel = MakeI18nLabel("lblInputLabel", "input.label", 9f, false, Theme.Muted);
            cardInput.Controls.Add(lblInputLabel);
            txtInput = new TextBox();
            txtInput.BorderStyle = BorderStyle.FixedSingle;
            txtInput.Font = Theme.F(10f, false);
            txtInput.BackColor = Color.White;
            cardInput.Controls.Add(txtInput);
            btnBrowseInput = MakeSecondaryButton();
            SetI18n(btnBrowseInput, "input.browse");
            btnBrowseInput.Font = Theme.F(9f, true);
            cardInput.Controls.Add(btnBrowseInput);

            lblOutputLabel = MakeI18nLabel("lblOutputLabel", "input.output", 9f, false, Theme.Muted);
            cardInput.Controls.Add(lblOutputLabel);
            txtOutput = new TextBox();
            txtOutput.BorderStyle = BorderStyle.FixedSingle;
            txtOutput.Font = Theme.F(10f, false);
            txtOutput.BackColor = Color.White;
            cardInput.Controls.Add(txtOutput);
            btnBrowseOutput = MakeSecondaryButton();
            SetI18n(btnBrowseOutput, "input.browse");
            btnBrowseOutput.Font = Theme.F(9f, true);
            cardInput.Controls.Add(btnBrowseOutput);

            lblTypeLabel = MakeI18nLabel("lblTypeLabel", "input.type", 9f, false, Theme.Muted);
            cardInput.Controls.Add(lblTypeLabel);
            cmbType = new ComboBox();
            cmbType.Name = "cmbType";
            cmbType.AccessibleName = "Input type";
            cmbType.DropDownStyle = ComboBoxStyle.DropDownList;
            cmbType.Font = Theme.F(9.5f, false);
            cmbType.BackColor = Color.White;
            cmbType.ForeColor = Theme.Text;
            cmbType.FlatStyle = FlatStyle.Flat;
            cmbType.Items.Add(Lang.T("input.type.file"));
            cmbType.Items.Add(Lang.T("input.type.dir"));
            cmbType.Items.Add(Lang.T("input.type.zip"));
            cmbType.SelectedIndex = 0;
            cardInput.Controls.Add(cmbType);
            lblHint = MakeI18nLabel("lblHint", "input.hint", 8.5f, false, Theme.Faint);
            cardInput.Controls.Add(lblHint);

            cardOptions = new CardPanel();
            Controls.Add(cardOptions);
            lblModeLabel = MakeI18nLabel("lblModeLabel", "opt.mode", 9f, false, Theme.Muted);
            cardOptions.Controls.Add(lblModeLabel);
            cmbMode = new ComboBox();
            cmbMode.DropDownStyle = ComboBoxStyle.DropDownList;
            cmbMode.Font = Theme.F(9.5f, false);
            cmbMode.BackColor = Color.White;
            cmbMode.ForeColor = Theme.Text;
            cmbMode.FlatStyle = FlatStyle.Flat;
            cmbMode.Items.Add(Lang.T("opt.mode.auto"));
            cmbMode.Items.Add("tick");
            cmbMode.Items.Add("float");
            cmbMode.SelectedIndex = 0;
            cardOptions.Controls.Add(cmbMode);

            lblJobsLabel = MakeI18nLabel("lblJobsLabel", "opt.jobs", 9f, false, Theme.Muted);
            cardOptions.Controls.Add(lblJobsLabel);
            numJobs = new NumericUpDown();
            numJobs.Minimum = 1;
            numJobs.Maximum = 16;
            numJobs.Value = 4;
            numJobs.Font = Theme.F(9.5f, false);
            cardOptions.Controls.Add(numJobs);

            chkForce = new CheckBox();
            SetI18n(chkForce, "opt.force");
            chkForce.Font = Theme.F(9f, false);
            chkForce.ForeColor = Theme.Text;
            chkForce.BackColor = Color.White;
            chkForce.AutoSize = true;
            cardOptions.Controls.Add(chkForce);

            chkReplace = new CheckBox();
            SetI18n(chkReplace, "opt.replace");
            chkReplace.Font = Theme.F(9f, false);
            chkReplace.ForeColor = Theme.Text;
            chkReplace.BackColor = Color.White;
            chkReplace.AutoSize = true;
            cardOptions.Controls.Add(chkReplace);

            btnStart = new FlatButton();
            SetI18n(btnStart, "btn.start");
            cardOptions.Controls.Add(btnStart);
            btnStop = MakeSecondaryButton();
            SetI18n(btnStop, "btn.stop");
            btnStop.Enabled = false;
            cardOptions.Controls.Add(btnStop);

            cardProgress = new CardPanel();
            Controls.Add(cardProgress);
            lblProgressTitle = MakeI18nLabel("lblProgressTitle", "progress.title", 11f, true, Theme.Text);
            cardProgress.Controls.Add(lblProgressTitle);
            lnkOutput = new LinkLabel();
            SetI18n(lnkOutput, "link.outputDir");
            lnkOutput.AutoSize = true;
            lnkOutput.LinkColor = Theme.Accent;
            lnkOutput.ActiveLinkColor = Theme.AccentDark;
            lnkOutput.BackColor = Color.White;
            lnkOutput.Font = Theme.F(8.5f, false);
            cardProgress.Controls.Add(lnkOutput);

            progress = new SlimProgress();
            cardProgress.Controls.Add(progress);

            lblPercent = MakeLabel(Lang.T("progress.zero"), 9f, true, Theme.Text);
            cardProgress.Controls.Add(lblPercent);
            lblBytes = MakeLabel(Lang.T("progress.zeroBytes"), 8.5f, false, Theme.Muted);
            lblBytes.TextAlign = ContentAlignment.MiddleRight;
            cardProgress.Controls.Add(lblBytes);
            lblCurrent = MakeLabel(Lang.T("progress.waiting"), 8.8f, false, Theme.Muted);
            lblCurrent.AutoEllipsis = true;
            cardProgress.Controls.Add(lblCurrent);

            statCaptions = new Label[5];
            statValues = new Label[5];
            string[] caps = new string[] { "stat.input", "stat.output", "stat.ratio", "stat.time", "stat.speed" };
            for (int i = 0; i < 5; i++)
            {
                statCaptions[i] = MakeI18nLabel("statCap" + i, caps[i], 8f, false, Theme.Faint);
                statValues[i] = MakeLabel("—", 11.5f, true, Theme.Text);
                cardProgress.Controls.Add(statCaptions[i]);
                cardProgress.Controls.Add(statValues[i]);
            }

            cardGrid = new CardPanel();
            Controls.Add(cardGrid);
            lblGridTitle = MakeI18nLabel("lblGridTitle", "grid.title", 11f, true, Theme.Text);
            cardGrid.Controls.Add(lblGridTitle);
            grid = new DataGridView();
            BuildGrid();
            cardGrid.Controls.Add(grid);

            cardLog = new CardPanel();
            Controls.Add(cardLog);
            lblLogTitle = MakeI18nLabel("lblLogTitle", "log.title", 10f, true, Theme.Text);
            cardLog.Controls.Add(lblLogTitle);
            lnkClear = new LinkLabel();
            SetI18n(lnkClear, "log.clear");
            lnkClear.AutoSize = true;
            lnkClear.LinkColor = Theme.Muted;
            lnkClear.BackColor = Color.White;
            lnkClear.Font = Theme.F(8.5f, false);
            cardLog.Controls.Add(lnkClear);
            log = new RichTextBox();
            log.BorderStyle = BorderStyle.None;
            log.BackColor = Color.FromArgb(15, 23, 42);
            log.ForeColor = Color.FromArgb(203, 213, 225);
            log.Font = new Font("Consolas", 8.8f, FontStyle.Regular, GraphicsUnit.Point);
            log.ReadOnly = true;
            log.WordWrap = false;
            log.DetectUrls = false;
            log.ScrollBars = RichTextBoxScrollBars.Vertical;
            cardLog.Controls.Add(log);

            lblStatus = MakeLabel(Lang.T("status.ready"), 8.5f, false, Theme.Muted);
            Controls.Add(lblStatus);
            lblNode = MakeLabel("", 8.5f, false, Theme.Faint);
            lblNode.TextAlign = ContentAlignment.MiddleRight;
            Controls.Add(lblNode);

            cmbLang = new ComboBox();
            cmbLang.Name = "cmbLang";
            cmbLang.AccessibleName = "Language";
            cmbLang.DropDownStyle = ComboBoxStyle.DropDownList;
            cmbLang.Font = Theme.F(8.5f, false);
            cmbLang.BackColor = Color.White;
            cmbLang.ForeColor = Theme.Text;
            cmbLang.FlatStyle = FlatStyle.Flat;
            cmbLang.Items.Add(Lang.T("lang.auto"));
            cmbLang.Items.Add("简体中文");
            cmbLang.Items.Add("English");
            cmbLang.SelectedIndex = Lang.Mode == "zh" ? 1 : Lang.Mode == "en" ? 2 : 0;
            Controls.Add(cmbLang);
            cmbLang.BringToFront();

            btnBrowseInput.Click += delegate { BrowseInput(); };
            btnBrowseOutput.Click += delegate { BrowseOutput(); };
            btnStart.Click += delegate { StartPack(); };
            btnStop.Click += delegate { StopPack(); };
            lnkClear.LinkClicked += delegate { log.Clear(); };
            lnkOutput.LinkClicked += delegate { OpenOutputDir(); };
            cmbType.SelectedIndexChanged += delegate { if (!applyingLanguage) ModeChanged(); };
            cmbLang.SelectedIndexChanged += delegate
            {
                if (applyingLanguage) return;
                string mode = cmbLang.SelectedIndex == 1 ? "zh" : cmbLang.SelectedIndex == 2 ? "en" : "auto";
                AppSettings.Set("language", mode);
                AppSettings.Save();
                Lang.SetMode(mode);
                ApplyLanguage();
                AppendLog(Lang.F("log.language", Lang.DisplayName), Theme.Muted);
            };
            DragEnter += OnDragEnter;
            DragDrop += OnDragDrop;
            FormClosing += delegate { AppSettings.Save(); StopPack(); };
            Shown += delegate
            {
                LayoutUi();
                CheckNodeAsync();
                BeginInvoke(new Action(delegate
                {
                    Activate();
                    txtInput.SelectionLength = 0;
                    txtOutput.SelectionLength = 0;
                    btnStart.Focus();
                }));
            };
            Resize += delegate { LayoutUi(); };
        }

        private void ApplyLanguage()
        {
            if (applyingLanguage) return;
            applyingLanguage = true;
            try
            {
                Text = Lang.T("app.title");
                header.Subtitle = Lang.T("header.subtitle");
                header.Invalidate();
                TranslateControlTree(this);

                int mi = cmbMode.SelectedIndex;
                if (mi < 0) mi = 0;
                cmbMode.BeginUpdate();
                cmbMode.Items.Clear();
                cmbMode.Items.Add(Lang.T("opt.mode.auto"));
                cmbMode.Items.Add("tick");
                cmbMode.Items.Add("float");
                if (mi < cmbMode.Items.Count) cmbMode.SelectedIndex = mi;
                cmbMode.EndUpdate();

                int ti = cmbType.SelectedIndex;
                if (ti < 0) ti = 0;
                cmbType.BeginUpdate();
                cmbType.Items.Clear();
                cmbType.Items.Add(Lang.T("input.type.file"));
                cmbType.Items.Add(Lang.T("input.type.dir"));
                cmbType.Items.Add(Lang.T("input.type.zip"));
                if (ti < cmbType.Items.Count) cmbType.SelectedIndex = ti;
                cmbType.EndUpdate();

                cmbLang.BeginUpdate();
                cmbLang.Items.Clear();
                cmbLang.Items.Add(Lang.T("lang.auto"));
                cmbLang.Items.Add("简体中文");
                cmbLang.Items.Add("English");
                cmbLang.SelectedIndex = Lang.Mode == "zh" ? 1 : Lang.Mode == "en" ? 2 : 0;
                cmbLang.EndUpdate();

                for (int i = 0; i < grid.Columns.Count; i++)
                {
                    string key = grid.Columns[i].Tag as string;
                    if (key != null && key.StartsWith("i18n:"))
                        grid.Columns[i].HeaderText = Lang.T(key.Substring(5));
                }
                foreach (DataGridViewRow row in grid.Rows)
                {
                    string key = row.Cells["status"].Tag as string;
                    if (key != null && key.StartsWith("i18n:"))
                        row.Cells["status"].Value = Lang.T(key.Substring(5));
                }

                btnStart.Text = running ? Lang.T("btn.running") : Lang.T("btn.start");
                btnStop.Text = Lang.T("btn.stop");
                if (!running)
                {
                    if (totalFiles > 0)
                    {
                        lblPercent.Text = "100%";
                        lblBytes.Text = Ui.Bytes(doneBytes) + " / " + Ui.Bytes(totalBytes);
                        lblCurrent.Text = Lang.F("progress.allDone", doneFiles, totalFiles);
                        lblCurrent.ForeColor = failed > 0 ? Theme.Red : Theme.Green;
                        lblStatus.Text = failed > 0 ? Lang.F("status.doneFail", failed) : Lang.F("status.done", totalFiles);
                        lblStatus.ForeColor = failed > 0 ? Theme.Red : Theme.Green;
                    }
                    else
                    {
                        lblPercent.Text = Lang.T("progress.zero");
                        lblBytes.Text = Lang.T("progress.zeroBytes");
                        lblCurrent.Text = Lang.T("progress.waiting");
                        lblCurrent.ForeColor = Theme.Muted;
                        lblStatus.Text = Lang.T("status.ready");
                        lblStatus.ForeColor = Theme.Muted;
                    }
                }
                CheckNodeAsync();
            }
            finally
            {
                applyingLanguage = false;
            }
            LayoutUi();
        }

        private void TranslateControlTree(Control parent)
        {
            foreach (Control c in parent.Controls)
            {
                string key = c.Tag as string;
                if (key != null && key.StartsWith("i18n:")) c.Text = Lang.T(key.Substring(5));
                if (c.HasChildren) TranslateControlTree(c);
            }
        }

        private void BuildGrid()
        {
            grid.ReadOnly = true;
            grid.AllowUserToAddRows = false;
            grid.AllowUserToDeleteRows = false;
            grid.AllowUserToResizeRows = false;
            grid.RowHeadersVisible = false;
            grid.MultiSelect = false;
            grid.SelectionMode = DataGridViewSelectionMode.FullRowSelect;
            grid.BackgroundColor = Color.White;
            grid.BorderStyle = BorderStyle.None;
            grid.CellBorderStyle = DataGridViewCellBorderStyle.SingleHorizontal;
            grid.GridColor = Color.FromArgb(238, 242, 247);
            grid.EnableHeadersVisualStyles = false;
            grid.ColumnHeadersHeight = 34;
            grid.RowTemplate.Height = 28;
            grid.AutoSizeColumnsMode = DataGridViewAutoSizeColumnsMode.Fill;
            grid.ScrollBars = ScrollBars.Vertical;
            grid.Font = Theme.F(8.8f, false);
            grid.DefaultCellStyle.Font = Theme.F(8.8f, false);
            grid.DefaultCellStyle.ForeColor = Theme.Text;
            grid.DefaultCellStyle.SelectionBackColor = Theme.SoftBlue;
            grid.DefaultCellStyle.SelectionForeColor = Theme.Text;
            grid.DefaultCellStyle.Padding = new Padding(4, 0, 4, 0);
            grid.AlternatingRowsDefaultCellStyle.BackColor = Color.FromArgb(250, 251, 253);
            grid.ColumnHeadersDefaultCellStyle.BackColor = Color.FromArgb(241, 245, 249);
            grid.ColumnHeadersDefaultCellStyle.ForeColor = Color.FromArgb(71, 85, 105);
            grid.ColumnHeadersDefaultCellStyle.Font = Theme.F(8.5f, true);
            grid.ColumnHeadersDefaultCellStyle.SelectionBackColor = Color.FromArgb(241, 245, 249);
            grid.ColumnHeadersDefaultCellStyle.Padding = new Padding(4, 0, 4, 0);

            AddCol("status", "grid.status", 52);
            AddCol("name", "grid.name", 210);
            AddCol("inSize", "grid.input", 90);
            AddCol("outSize", "grid.output", 82);
            AddCol("ratio", "grid.ratio", 98);
            AddCol("time", "grid.time", 68);
            AddCol("speed", "grid.speed", 88);
            AddCol("notes", "grid.notes", 92);
            AddCol("groups", "grid.groups", 70);
            AddCol("mode", "grid.mode", 58);
        }

        private void AddCol(string name, string key, int weight)
        {
            DataGridViewTextBoxColumn c = new DataGridViewTextBoxColumn();
            c.Name = name;
            c.HeaderText = Lang.T(key);
            c.Tag = "i18n:" + key;
            c.FillWeight = weight;
            c.SortMode = DataGridViewColumnSortMode.NotSortable;
            c.ReadOnly = true;
            grid.Columns.Add(c);
        }

        private void LayoutUi()
        {
            if (header == null) return;
            float s = S;
            int W = ClientSize.Width, H = ClientSize.Height;
            int m = X(18);
            header.Bounds = new Rectangle(0, 0, W, X(78));
            cmbLang.Bounds = new Rectangle(W - X(196), X(18), X(160), X(28));

            int inputH = X(164);
            cardInput.Bounds = new Rectangle(m, header.Bottom + X(12), W - m * 2, inputH);
            LayoutInputCard();

            int optH = X(84);
            cardOptions.Bounds = new Rectangle(m, cardInput.Bottom + X(10), W - m * 2, optH);
            LayoutOptionsCard();

            int progH = X(154);
            cardProgress.Bounds = new Rectangle(m, cardOptions.Bottom + X(10), W - m * 2, progH);
            LayoutProgressCard();

            int logH = X(122);
            cardLog.Bounds = new Rectangle(m, H - X(36) - logH, W - m * 2, logH);
            LayoutLogCard();

            cardGrid.Bounds = new Rectangle(m, cardProgress.Bottom + X(10), W - m * 2,
                Math.Max(X(90), cardLog.Top - X(10) - (cardProgress.Bottom + X(10))));
            LayoutGridCard();

            lblStatus.Bounds = new Rectangle(m, H - X(30), W / 2, X(20));
            lblNode.Bounds = new Rectangle(W / 2, H - X(30), W / 2 - m, X(20));

            // footer/status font
            lblStatus.Font = Theme.F(8.5f, false);
            lblNode.Font = Theme.F(8.5f, false);
        }

        private void LayoutInputCard()
        {
            int w = cardInput.Width;
            int pad = X(20);
            int labW = X(48), fieldX = pad + labW;
            int fieldW = w - fieldX - X(126) - pad;

            lblInputTitle.Bounds = new Rectangle(pad, X(10), X(240), X(24));
            lblInputLabel.Bounds = new Rectangle(pad, X(44), labW, X(30));
            txtInput.Bounds = new Rectangle(fieldX, X(42), fieldW, X(32));
            btnBrowseInput.Bounds = new Rectangle(w - X(112) - pad, X(42), X(112), X(32));
            lblOutputLabel.Bounds = new Rectangle(pad, X(82), labW, X(30));
            txtOutput.Bounds = new Rectangle(fieldX, X(80), fieldW, X(32));
            btnBrowseOutput.Bounds = new Rectangle(w - X(112) - pad, X(80), X(112), X(32));

            int y = X(120);
            lblTypeLabel.Bounds = new Rectangle(pad, y, labW, X(28));
            cmbType.Bounds = new Rectangle(fieldX, y - X(2), X(220), X(30));
            lblHint.Bounds = new Rectangle(fieldX + X(232), y, w - fieldX - X(232) - pad, X(28));
        }

        private void LayoutOptionsCard()
        {
            int w = cardOptions.Width;
            int pad = X(20);
            lblModeLabel.Bounds = new Rectangle(pad, X(29), X(82), X(28));
            cmbMode.Bounds = new Rectangle(pad + X(86), X(26), X(150), X(30));
            lblJobsLabel.Bounds = new Rectangle(pad + X(266), X(29), X(62), X(28));
            numJobs.Bounds = new Rectangle(pad + X(330), X(26), X(64), X(30));
            chkForce.Bounds = new Rectangle(pad + X(404), X(29), X(180), X(26));
            chkReplace.Bounds = new Rectangle(pad + X(590), X(29), X(210), X(26));
            btnStop.Bounds = new Rectangle(w - pad - X(92), X(20), X(92), X(42));
            btnStart.Bounds = new Rectangle(w - pad - X(92) - X(12) - X(132), X(20), X(132), X(42));
        }

        private void LayoutProgressCard()
        {
            int w = cardProgress.Width;
            int pad = X(20);
            lblProgressTitle.Bounds = new Rectangle(pad, X(10), X(200), X(24));
            lnkOutput.Bounds = new Rectangle(w - X(120) - pad, X(12), X(120), X(20));
            progress.Bounds = new Rectangle(pad, X(40), w - pad * 2, X(10));
            lblPercent.Bounds = new Rectangle(pad, X(55), X(80), X(20));
            lblBytes.Bounds = new Rectangle(w - X(300) - pad, X(55), X(300), X(20));
            lblCurrent.Bounds = new Rectangle(pad, X(76), w - pad * 2, X(22));

            int blockW = (w - pad * 2) / 5;
            for (int i = 0; i < 5; i++)
            {
                statCaptions[i].Bounds = new Rectangle(pad + blockW * i, X(104), blockW - X(8), X(18));
                statValues[i].Bounds = new Rectangle(pad + blockW * i, X(120), blockW - X(8), X(26));
            }
        }

        private void LayoutGridCard()
        {
            int pad = X(16);
            lblGridTitle.Bounds = new Rectangle(pad + X(4), X(12), X(200), X(24));
            grid.Bounds = new Rectangle(pad, X(40), cardGrid.Width - pad * 2, cardGrid.Height - X(52));
        }

        private void LayoutLogCard()
        {
            int pad = X(16);
            lblLogTitle.Bounds = new Rectangle(pad + X(4), X(8), X(100), X(22));
            lnkClear.Bounds = new Rectangle(cardLog.Width - X(60) - pad, X(10), X(60), X(18));
            log.Bounds = new Rectangle(pad, X(32), cardLog.Width - pad * 2, cardLog.Height - X(42));
        }

        private string CurrentMode()
        {
            if (cmbType.SelectedIndex == 1) return "dir";
            if (cmbType.SelectedIndex == 2) return "zip";
            return "file";
        }

        private void LoadSettings()
        {
            string lastIn = AppSettings.Get("lastInput", "");
            string lastOut = AppSettings.Get("lastOutput", "");
            int jobs = AppSettings.GetInt("jobs", 4);
            if (jobs < 1) jobs = 1;
            if (jobs > 16) jobs = 16;
            numJobs.Value = jobs;
            string mode = AppSettings.Get("timeMode", "auto");
            cmbMode.SelectedIndex = mode == "tick" ? 1 : mode == "float" ? 2 : 0;
            if (lastIn.Length > 0) txtInput.Text = lastIn;
            if (lastIn.Length > 0) DetectModeFromInput(lastIn);
            if (lastOut.Length > 0) txtOutput.Text = lastOut;
        }

        private void ModeChanged()
        {
            if (applyingLanguage) return;
            UpdateModeUi();
            string input = txtInput.Text.Trim();
            if (input.Length == 0) return;
            string output = DefaultOutputFor(CurrentMode(), input);
            if (output != null) txtOutput.Text = output;
        }

        private void UpdateModeUi()
        {
            if (CurrentMode() == "file")
            {
                SetI18n(btnBrowseInput, "input.chooseJson");
                SetI18n(btnBrowseOutput, "input.saveAs");
            }
            else
            {
                SetI18n(btnBrowseInput, "input.browse");
                SetI18n(btnBrowseOutput, "input.browse");
            }
            chkReplace.Enabled = CurrentMode() == "dir" && !running;
        }

        private void DetectModeFromInput(string p)
        {
            try
            {
                if (Directory.Exists(p)) cmbType.SelectedIndex = 1;
                else if (p.EndsWith(".zip", StringComparison.OrdinalIgnoreCase)) cmbType.SelectedIndex = 2;
                else cmbType.SelectedIndex = 0;
            }
            catch { }
        }

        private string DefaultOutputFor(string mode, string p)
        {
            try
            {
                if (mode == "dir")
                {
                    if (Directory.Exists(p)) return p;
                    return null;
                }
                if (mode == "zip")
                {
                    if (File.Exists(p) && p.EndsWith(".zip", StringComparison.OrdinalIgnoreCase))
                        return Path.GetDirectoryName(p);
                    return null;
                }
                if (mode == "file")
                {
                    if (File.Exists(p) && p.EndsWith(".json", StringComparison.OrdinalIgnoreCase))
                        return DefaultFileOutput(p);
                    return null;
                }
            }
            catch { }
            return null;
        }

        private void ApplyDetectedInput(string p)
        {
            DetectModeFromInput(p);
            string output = DefaultOutputFor(CurrentMode(), p);
            if (output != null && output.Length > 0) txtOutput.Text = output;
        }

        private void BrowseInput()
        {
            string mode = CurrentMode();
            if (mode == "dir")
            {
                using (FolderBrowserDialog d = new FolderBrowserDialog())
                {
                    d.Description = Lang.T("input.dialog.folder");
                    if (txtInput.Text.Length > 0 && Directory.Exists(txtInput.Text)) d.SelectedPath = txtInput.Text;
                    if (d.ShowDialog(this) == DialogResult.OK) { txtInput.Text = d.SelectedPath; ApplyDetectedInput(d.SelectedPath); }
                }
            }
            else
            {
                using (OpenFileDialog d = new OpenFileDialog())
                {
                    d.Title = mode == "zip" ? Lang.T("input.dialog.zip") : Lang.T("input.dialog.json");
                    d.Filter = mode == "zip" ? Lang.T("input.filter.zip") : Lang.T("input.filter.json");
                    if (d.ShowDialog(this) == DialogResult.OK) { txtInput.Text = d.FileName; ApplyDetectedInput(d.FileName); }
                }
            }
        }

        private void BrowseOutput()
        {
            if (CurrentMode() == "file")
            {
                using (SaveFileDialog d = new SaveFileDialog())
                {
                    d.Title = Lang.T("input.saveTitle");
                    d.Filter = Lang.T("input.filter.chartpack");
                    string input = txtInput.Text.Trim();
                    if (input.Length > 0) d.FileName = Path.GetFileNameWithoutExtension(input) + ".chartpack";
                    if (txtOutput.Text.Length > 0) d.InitialDirectory = Path.GetDirectoryName(txtOutput.Text);
                    if (d.ShowDialog(this) == DialogResult.OK) txtOutput.Text = d.FileName;
                }
            }
            else
            {
                using (FolderBrowserDialog d = new FolderBrowserDialog())
                {
                    d.Description = Lang.T("input.outputFolder");
                    if (txtOutput.Text.Length > 0 && Directory.Exists(txtOutput.Text)) d.SelectedPath = txtOutput.Text;
                    if (d.ShowDialog(this) == DialogResult.OK) txtOutput.Text = d.SelectedPath;
                }
            }
        }

        private void OnDragEnter(object sender, DragEventArgs e)
        {
            if (e.Data.GetDataPresent(DataFormats.FileDrop)) e.Effect = DragDropEffects.Copy;
            else e.Effect = DragDropEffects.None;
        }

        private void OnDragDrop(object sender, DragEventArgs e)
        {
            string[] files = e.Data.GetData(DataFormats.FileDrop) as string[];
            if (files == null || files.Length == 0) return;
            string p = files[0];
            txtInput.Text = p;
            ApplyDetectedInput(p);
            AppendLog(Lang.F("log.selected", p), Theme.Muted);
        }

        private void CheckNodeAsync()
        {
            ThreadPool.QueueUserWorkItem(delegate
            {
                string node = NodeLocator.Find();
                string text;
                Color color;
                if (node == null)
                {
                    text = Lang.T("status.nodeMissing");
                    color = Theme.Red;
                }
                else
                {
                    string ver = NodeLocator.GetVersion(node);
                    if (ver.Length == 0)
                    {
                        text = Lang.T("status.nodeBad");
                        color = Theme.Red;
                    }
                    else
                    {
                        text = Lang.F("status.nodeInfo", ver, Environment.ProcessorCount);
                        color = Theme.Faint;
                    }
                }
                try
                {
                    BeginInvoke(new Action(delegate
                    {
                        lblNode.Text = text;
                        lblNode.ForeColor = color;
                    }));
                }
                catch { }
            });
        }

        private void AppendLog(string line)
        {
            AppendLog(line, Color.FromArgb(203, 213, 225));
        }

        private void AppendLog(string line, Color color)
        {
            if (log == null) return;
            if (log.TextLength > 400000) log.Clear();
            log.SelectionStart = log.TextLength;
            log.SelectionLength = 0;
            log.SelectionColor = color;
            log.AppendText("[" + DateTime.Now.ToString("HH:mm:ss") + "] " + line + Environment.NewLine);
            log.SelectionColor = log.ForeColor;
            log.ScrollToCaret();
        }

        private void OpenOutputDir()
        {
            try
            {
                string p = txtOutput.Text.Trim();
                if (CurrentMode() == "file") p = Path.GetDirectoryName(p);
                if (Directory.Exists(p)) Process.Start("explorer.exe", "\"" + p + "\"");
                else if (File.Exists(p)) Process.Start("explorer.exe", "/select,\"" + p + "\"");
            }
            catch { }
        }

        private string ResolveOutput(string mode, string input)
        {
            string output = txtOutput.Text.Trim();
            if (mode == "file")
            {
                if (output.Length == 0)
                    output = Path.Combine(Path.GetDirectoryName(input), Path.GetFileNameWithoutExtension(input) + ".chartpack");
                if (Directory.Exists(output))
                    output = Path.Combine(output, Path.GetFileNameWithoutExtension(input) + ".chartpack");
                if (!output.EndsWith(".chartpack", StringComparison.OrdinalIgnoreCase)) output += ".chartpack";
                string full = Path.GetFullPath(output);
                string dir = Path.GetDirectoryName(full);
                if (dir != null && dir.Length > 0) Directory.CreateDirectory(dir);
                return full;
            }

            if (output.Length == 0)
                output = mode == "dir" ? input : Path.GetDirectoryName(input);
            if (File.Exists(output)) output = Path.GetDirectoryName(output);
            string fullDir = Path.GetFullPath(output);
            Directory.CreateDirectory(fullDir);
            string root = Path.GetPathRoot(fullDir);
            if (root != null && fullDir.Length > root.Length) fullDir = fullDir.TrimEnd('\\', '/');
            return fullDir;
        }

        private string DefaultFileOutput(string input)
        {
            string dir = Path.GetDirectoryName(input);
            return Path.Combine(dir, Path.GetFileNameWithoutExtension(input) + ".chartpack");
        }

        private bool InputMatchesMode(string mode, string input)
        {
            try
            {
                if (mode == "dir") return Directory.Exists(input);
                if (mode == "zip") return File.Exists(input) && input.EndsWith(".zip", StringComparison.OrdinalIgnoreCase);
                if (mode == "file") return File.Exists(input) && input.EndsWith(".json", StringComparison.OrdinalIgnoreCase);
            }
            catch { }
            return false;
        }

        private void StartPack()
        {
            if (running) return;
            string input = txtInput.Text.Trim();
            if (input.Length == 0 || (!File.Exists(input) && !Directory.Exists(input)))
            {
                MessageBox.Show(this, Lang.T("dlg.inputInvalid.msg"), Lang.T("dlg.inputInvalid.title"),
                    MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }

            string mode = CurrentMode();
            if (!InputMatchesMode(mode, input))
            {
                MessageBox.Show(this, Lang.F("dlg.typeMismatch.msg", Lang.T("input.type." + mode)),
                    Lang.T("dlg.typeMismatch.title"), MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }

            if (mode == "file" && txtOutput.Text.Trim().Length == 0) txtOutput.Text = DefaultFileOutput(input);

            string output;
            try { output = ResolveOutput(mode, input); }
            catch (Exception ex)
            {
                MessageBox.Show(this, Lang.F("dlg.outputInvalid.msg", ex.Message), Lang.T("dlg.outputInvalid.title"),
                    MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }

            string version;
            string node = NodeHelper.Ensure(this, out version);
            if (node == null) return;

            string script;
            try { script = ScriptProvider.GetScriptPath(); }
            catch (Exception ex)
            {
                MessageBox.Show(this, ex.Message, Lang.T("dlg.scriptMissing.title"), MessageBoxButtons.OK, MessageBoxIcon.Error);
                return;
            }

            string timeMode = cmbMode.SelectedIndex == 1 ? "tick" : cmbMode.SelectedIndex == 2 ? "float" : "auto";
            bool replace = chkReplace.Checked && mode == "dir";
            if (replace)
            {
                DialogResult confirm = MessageBox.Show(this,
                    Lang.T("dlg.confirmReplace.msg"),
                    Lang.T("dlg.confirmReplace.title"), MessageBoxButtons.YesNo, MessageBoxIcon.Warning, MessageBoxDefaultButton.Button2);
                if (confirm != DialogResult.Yes) return;
            }
            string args = Commands.Build(mode, input, output, (int)numJobs.Value, timeMode, chkForce.Checked, replace);

            AppSettings.Set("lastInput", input);
            AppSettings.Set("lastOutput", output);
            AppSettings.Set("jobs", ((int)numJobs.Value).ToString(CultureInfo.InvariantCulture));
            AppSettings.Set("timeMode", timeMode);
            AppSettings.Save();

            rowsByIndex.Clear();
            grid.Rows.Clear();
            totalBytes = 0; doneBytes = 0; totalOut = 0;
            totalFiles = 0; doneFiles = 0; failed = 0; skipped = 0;
            startedAt = DateTime.Now;
            stopped = false;
            progress.Indeterminate = true;
            progress.Value = 0;
            lblPercent.Text = Lang.T("progress.zero");
            lblBytes.Text = Lang.T("progress.zeroBytes");
            lblCurrent.Text = Lang.T("progress.starting");
            lblCurrent.ForeColor = Theme.Muted;
            lblStatus.Text = Lang.T("status.running");
            lblStatus.ForeColor = Theme.Muted;
            statValues[0].Text = "—"; statValues[1].Text = "—"; statValues[2].Text = "—";
            statValues[3].Text = "—"; statValues[4].Text = "—";
            SetRunning(true);

            string kind = mode == "file" ? Lang.T("log.nodeKind.file")
                : mode == "dir" ? Lang.T("log.nodeKind.dir") : Lang.T("log.nodeKind.zip");
            AppendLog(Lang.F("log.node", version, kind, numJobs.Value), Theme.Muted);
            AppendLog(Lang.F("log.input", input));
            AppendLog(Lang.F("log.output", output));

            runner = new PackRunner();
            runner.EventReceived += OnPackEvent;
            runner.LogReceived += OnPackLog;
            runner.ProcessExited += OnPackExit;
            try
            {
                runner.Start(node, script, args);
            }
            catch (Exception ex)
            {
                AppendLog(Lang.F("log.startFailed", ex.Message), Theme.Red);
                lblStatus.Text = Lang.T("status.startFailed");
                lblStatus.ForeColor = Theme.Red;
                SetRunning(false);
                try { runner.Dispose(); } catch { }
                runner = null;
            }
        }

        private void StopPack()
        {
            if (!running) return;
            stopped = true;
            AppendLog(Lang.T("log.stopping"), Theme.Red);
            try { if (runner != null) runner.Stop(); } catch { }
        }

        private void OnPackEvent(Dictionary<string, object> d)
        {
            if (IsDisposed) return;
            if (InvokeRequired)
            {
                try { BeginInvoke(new Action<Dictionary<string, object>>(OnPackEvent), d); } catch { }
                return;
            }
            HandlePackEvent(d);
        }

        private void OnPackLog(string line, bool isError)
        {
            if (IsDisposed) return;
            if (InvokeRequired)
            {
                try { BeginInvoke(new Action<string, bool>(OnPackLog), line, isError); } catch { }
                return;
            }
            AppendLog(line, isError ? Theme.Red : Theme.Muted);
        }

        private void OnPackExit(int code)
        {
            if (IsDisposed) return;
            if (InvokeRequired)
            {
                try { BeginInvoke(new Action<int>(OnPackExit), code); } catch { }
                return;
            }
            if (runner != null) { try { runner.Dispose(); } catch { } runner = null; }
            if (running)
            {
                running = false;
                SetRunning(false);
                progress.Indeterminate = false;
                if (stopped)
                {
                    lblStatus.Text = Lang.T("status.stopped");
                    lblStatus.ForeColor = Theme.Muted;
                    AppendLog(Lang.T("log.stopped"), Theme.Muted);
                }
                else if (code == 0)
                {
                    lblStatus.Text = Lang.T("status.finished");
                    lblStatus.ForeColor = Theme.Green;
                }
                else
                {
                    lblStatus.Text = Lang.F("status.failedExit", code);
                    lblStatus.ForeColor = Theme.Red;
                    AppendLog(Lang.F("log.exit", code), Theme.Red);
                }
            }
        }

        private void HandlePackEvent(Dictionary<string, object> d)
        {
            string ev = Ui.GetStr(d, "event", "");
            if (ev == "plan")
            {
                totalBytes = Ui.GetLong(d, "totalBytes", 0);
                totalFiles = Ui.GetInt(d, "totalFiles", 0);
                skipped = Ui.GetInt(d, "skipped", 0);
                doneBytes = 0; totalOut = 0; doneFiles = 0; failed = 0;
                progress.Indeterminate = totalFiles == 0;
                progress.Value = 0;
                lblPercent.Text = totalFiles == 0 ? "—" : Lang.T("progress.zero");
                lblBytes.Text = "0 B / " + Ui.Bytes(totalBytes);
                lblCurrent.Text = totalFiles == 0 ? Lang.T("progress.none") : Lang.T("progress.preparing");
                lblStatus.Text = Lang.F("status.runningCount", 0, totalFiles);
                lblStatus.ForeColor = Theme.Muted;
                UpdateStats(0);
                string skip = skipped > 0 ? Lang.F("log.planSkipped", skipped) : "";
                AppendLog(Lang.F("log.plan", totalFiles, Ui.Bytes(totalBytes), skip), Theme.Muted);
            }
            else if (ev == "file-start")
            {
                int idx = Ui.GetInt(d, "index", 0);
                string name = Ui.GetStr(d, "name", "?");
                long ib = Ui.GetLong(d, "inputBytes", 0);
                DataGridViewRow row;
                if (!rowsByIndex.TryGetValue(idx, out row))
                {
                    int r = grid.Rows.Add(Lang.T("grid.processing"), name, Ui.Bytes(ib), "", "", "", "", "", "", "");
                    row = grid.Rows[r];
                    rowsByIndex[idx] = row;
                }
                row.Cells["status"].Value = Lang.T("grid.processing");
                row.Cells["status"].Tag = "i18n:grid.processing";
                row.Cells["status"].Style.ForeColor = Theme.Accent;
                row.Cells["name"].Value = name;
                row.Cells["inSize"].Value = Ui.Bytes(ib);
                lblCurrent.Text = name + "  ·  " + Ui.Bytes(ib);
                lblCurrent.ForeColor = Theme.Text;
                lblCurrent.Tag = idx;
            }
            else if (ev == "file-done")
            {
                int idx = Ui.GetInt(d, "index", 0);
                string name = Ui.GetStr(d, "name", "?");
                long ib = Ui.GetLong(d, "inputBytes", Ui.GetLong(d, "jsonBytes", 0));
                long ob = Ui.GetLong(d, "outBytes", 0);
                double ratio = Ui.GetDouble(d, "ratio", 0);
                double ms = Ui.GetDouble(d, "totalMs", Ui.GetDouble(d, "ms", 0));
                double mbps = Ui.GetDouble(d, "mbps", 0);
                long notes = Ui.GetLong(d, "notes", 0);
                long groups = Ui.GetLong(d, "groups", 0);
                string tm = Ui.GetStr(d, "timeMode", "");
                DataGridViewRow row;
                if (!rowsByIndex.TryGetValue(idx, out row))
                {
                    int r = grid.Rows.Add(Lang.T("grid.done"), name, Ui.Bytes(ib), "", "", "", "", "", "", "");
                    row = grid.Rows[r];
                    rowsByIndex[idx] = row;
                }
                row.Cells["status"].Value = Lang.T("grid.done");
                row.Cells["status"].Tag = "i18n:grid.done";
                row.Cells["status"].Style.ForeColor = Theme.Green;
                row.Cells["name"].Value = name;
                row.Cells["inSize"].Value = Ui.Bytes(ib);
                row.Cells["outSize"].Value = Ui.Bytes(ob);
                row.Cells["ratio"].Value = Ui.Ratio(ratio);
                row.Cells["time"].Value = Ui.Duration(ms);
                row.Cells["speed"].Value = Ui.Speed(mbps);
                row.Cells["notes"].Value = Ui.Count(notes);
                row.Cells["groups"].Value = Ui.Count(groups);
                row.Cells["mode"].Value = tm;
                doneBytes += ib;
                totalOut += ob;
                doneFiles++;
                UpdateProgress();
                AppendLog(Lang.F("log.fileDone", name, Ui.Bytes(ib), Ui.Bytes(ob), Ui.Ratio(ratio), Ui.Duration(ms), Ui.Speed(mbps)),
                    Color.FromArgb(134, 239, 172));
            }
            else if (ev == "file-error")
            {
                int idx = Ui.GetInt(d, "index", 0);
                string name = Ui.GetStr(d, "name", "?");
                string err = Ui.GetStr(d, "error", Lang.T("dlg.error"));
                DataGridViewRow row;
                if (!rowsByIndex.TryGetValue(idx, out row))
                {
                    int r = grid.Rows.Add(Lang.T("grid.failed"), name, Ui.Bytes(Ui.GetLong(d, "inputBytes", 0)), "", "", "", "", "", "", "");
                    row = grid.Rows[r];
                    rowsByIndex[idx] = row;
                }
                row.Cells["status"].Value = Lang.T("grid.failed");
                row.Cells["status"].Tag = "i18n:grid.failed";
                row.Cells["status"].Style.ForeColor = Theme.Red;
                row.Cells["name"].Value = name;
                row.Cells["name"].ToolTipText = err;
                failed++;
                AppendLog(Lang.F("log.fileError", name, err), Theme.Red);
                lblStatus.Text = Lang.F("status.runningFail", doneFiles, totalFiles, failed);
            }
            else if (ev == "summary")
            {
                running = false;
                totalFiles = Ui.GetInt(d, "totalFiles", totalFiles);
                failed = Ui.GetInt(d, "failed", failed);
                skipped = Ui.GetInt(d, "skipped", skipped);
                totalBytes = Ui.GetLong(d, "totalBytes", totalBytes);
                doneBytes = totalBytes;
                totalOut = Ui.GetLong(d, "totalOut", totalOut);
                doneFiles = totalFiles - failed;
                double elapsed = Ui.GetDouble(d, "elapsedMs", (DateTime.Now - startedAt).TotalMilliseconds);
                progress.Indeterminate = false;
                progress.Value = 1000;
                lblPercent.Text = totalFiles == 0 ? "—" : "100%";
                lblBytes.Text = Ui.Bytes(doneBytes) + " / " + Ui.Bytes(totalBytes);
                lblCurrent.Text = totalFiles == 0 ? Lang.T("progress.none")
                    : Lang.F("progress.allDone", doneFiles, totalFiles);
                lblCurrent.ForeColor = failed > 0 ? Theme.Red : Theme.Green;
                UpdateStats(elapsed);
                SetRunning(false);
                if (totalFiles == 0)
                {
                    lblStatus.Text = Lang.T("status.noFiles");
                    lblStatus.ForeColor = Theme.Muted;
                }
                else if (failed > 0)
                {
                    lblStatus.Text = Lang.F("status.doneFail", failed);
                    lblStatus.ForeColor = Theme.Red;
                }
                else
                {
                    lblStatus.Text = Lang.F("status.done", totalFiles);
                    lblStatus.ForeColor = Theme.Green;
                }
                AppendLog(Lang.F("log.done", Ui.Bytes(totalBytes), Ui.Bytes(totalOut),
                    Ui.Ratio(totalOut > 0 ? (double)totalBytes / totalOut : 0), Ui.Duration(elapsed)),
                    Color.FromArgb(147, 197, 253));
            }
        }

        private void UpdateProgress()
        {
            int p = 0;
            if (totalBytes > 0) p = (int)Math.Min(1000L, doneBytes * 1000L / totalBytes);
            progress.Indeterminate = false;
            progress.Value = p;
            lblPercent.Text = (p / 10.0).ToString("0.0", CultureInfo.InvariantCulture) + "%";
            lblBytes.Text = Ui.Bytes(doneBytes) + " / " + Ui.Bytes(totalBytes);
            lblStatus.Text = failed > 0 ? Lang.F("status.runningFail", doneFiles, totalFiles, failed)
                : Lang.F("status.runningCount", doneFiles, totalFiles);
            lblStatus.ForeColor = failed > 0 ? Theme.Red : Theme.Muted;
            UpdateStats((DateTime.Now - startedAt).TotalMilliseconds);
        }

        private void SetRunning(bool value)
        {
            running = value;
            cmbType.Enabled = !value;
            txtInput.ReadOnly = value;
            txtOutput.ReadOnly = value;
            btnBrowseInput.Enabled = !value;
            btnBrowseOutput.Enabled = !value;
            cmbMode.Enabled = !value;
            cmbLang.Enabled = !value;
            numJobs.Enabled = !value;
            chkForce.Enabled = !value;
            chkReplace.Enabled = !value && CurrentMode() == "dir";
            btnStart.Enabled = !value;
            btnStop.Enabled = value;
            btnStart.Text = value ? Lang.T("btn.running") : Lang.T("btn.start");
        }


        public void Prefill(string input, string output)
        {
            if (input != null && input.Length > 0)
            {
                txtInput.Text = input;
                ApplyDetectedInput(input);
            }
            if (output != null && output.Length > 0) txtOutput.Text = output;
        }

        public void StartFromCommandLine()
        {
            StartPack();
        }

        public void SeedDemo()
        {
            cmbType.SelectedIndex = 2;
            txtInput.Text = @"O:\Downloads\funeral-only-jsons-files (1).zip";
            txtOutput.Text = @"O:\Downloads\funeral-only-jsons-files (1)";
            cmbMode.SelectedIndex = 0;
            numJobs.Value = 4;
            totalBytes = 76765170749L;
            doneBytes = totalBytes;
            totalOut = 20834;
            totalFiles = 17;
            doneFiles = 17;
            failed = 0;
            progress.Value = 1000;
            lblPercent.Text = "100%";
            lblBytes.Text = Ui.Bytes(totalBytes) + " / " + Ui.Bytes(totalBytes);
            lblCurrent.Text = Lang.F("progress.allDone", 17, 17);
            lblStatus.Text = Lang.F("status.done", 17);
            lblNode.Text = Lang.F("status.nodeInfo", "v24.19.0", 12);
            UpdateStats(21080);

            string[,] demo = new string[,]
            {
                { "funeral-11.json", "6681068673", "1392", "4799618", "5900", "1082", "268435456", "32768" },
                { "funeral-12.json", "6676677761", "1391", "4799912", "5920", "1078", "268435456", "32768" },
                { "funeral-13.json", "6254789742", "1351", "4629748", "5470", "1092", "251658240", "30720" },
                { "funeral-14.json", "6253872238", "1351", "4629069", "5210", "1146", "251658240", "30720" },
                { "funeral-15.json", "6253577326", "1352", "4625427", "5350", "1117", "251658240", "30720" },
                { "funeral-16.json", "6252299374", "1352", "4624482", "5360", "1114", "251658240", "30720" },
                { "funeral-17.json", "1667925113", "930", "1793468", "1540", "1034", "67108864", "8192" }
            };
            for (int i = 0; i < demo.GetLength(0); i++)
            {
                int idx = grid.Rows.Add(Lang.T("grid.done"), demo[i, 0], Ui.Bytes(long.Parse(demo[i, 1])), Ui.Bytes(long.Parse(demo[i, 2])),
                    Ui.Ratio(double.Parse(demo[i, 3])), Ui.Duration(double.Parse(demo[i, 4])), Ui.Speed(double.Parse(demo[i, 5])),
                    Ui.Count(long.Parse(demo[i, 6])), Ui.Count(long.Parse(demo[i, 7])), "tick");
                DataGridViewRow row = grid.Rows[idx];
                row.Cells["status"].Tag = "i18n:grid.done";
                row.Cells["status"].Style.ForeColor = Theme.Green;
            }
            AppendLog(Lang.F("log.plan", 17, Ui.Bytes(totalBytes), ""), Theme.Muted);
            AppendLog("✓ funeral-11.json  6.22 GiB → 1.4 KiB  (4,799,618×)  5.90 s  1082 MB/s", Color.FromArgb(134, 239, 172));
            AppendLog("✓ funeral-15.json  5.82 GiB → 1.3 KiB  (4,625,427×)  5.35 s  1117 MB/s", Color.FromArgb(134, 239, 172));
            AppendLog("✓ funeral-17.json  1.55 GiB → 930 B    (1,793,468×)  1.54 s  1034 MB/s", Color.FromArgb(134, 239, 172));
            AppendLog(Lang.F("log.done", Ui.Bytes(76765170749L), "20.3 KiB", "3,684,610×", "21.08 s"), Color.FromArgb(147, 197, 253));
            txtInput.SelectionLength = 0;
            txtOutput.SelectionLength = 0;
            ActiveControl = null;
        }

        private void UpdateStats(double elapsedMs)
        {
            statValues[0].Text = Ui.Bytes(doneBytes);
            statValues[1].Text = Ui.Bytes(totalOut);
            statValues[2].Text = Ui.Ratio(totalOut > 0 ? (double)doneBytes / totalOut : 0);
            statValues[3].Text = Ui.Duration(elapsedMs);
            statValues[4].Text = Ui.Speed(elapsedMs > 0 ? doneBytes / 1048576.0 / (elapsedMs / 1000.0) : 0);
        }
    }

    internal static class Program
    {
        [DllImport("user32.dll")]
        private static extern bool SetProcessDPIAware();


        private static string ArgValue(string[] args, string name, string def)
        {
            for (int i = 0; i < args.Length - 1; i++)
                if (args[i] == name) return args[i + 1];
            return def;
        }

        private static bool HasFlag(string[] args, string name)
        {
            for (int i = 0; i < args.Length; i++) if (args[i] == name) return true;
            return false;
        }

        private static void SelfTest(string outFile)
        {
            StringBuilder sb = new StringBuilder();
            string node = NodeLocator.Find();
            string script = "";
            string error = "";
            try { script = ScriptProvider.GetScriptPath(); }
            catch (Exception ex) { error = ex.Message; }
            string ver = node != null ? NodeLocator.GetVersion(node) : "";
            sb.AppendLine("node=" + (node == null ? "" : node));
            sb.AppendLine("version=" + ver);
            sb.AppendLine("script=" + script);
            sb.AppendLine("scriptExists=" + (script.Length > 0 && File.Exists(script)));
            sb.AppendLine("scriptBytes=" + (script.Length > 0 && File.Exists(script) ? new FileInfo(script).Length.ToString(CultureInfo.InvariantCulture) : "0"));
            sb.AppendLine("error=" + error);
            File.WriteAllText(outFile, sb.ToString(), Encoding.UTF8);
        }

        private static void RunHeadless(string[] args)
        {
            string input = args.Length > 1 ? args[1] : "";
            string output = ArgValue(args, "--out", "");
            string logPath = ArgValue(args, "--log", Path.Combine(Path.GetTempPath(), "chartpack-ui-run.log"));
            int jobs = 4;
            int.TryParse(ArgValue(args, "--jobs", "4"), out jobs);
            string timeMode = ArgValue(args, "--mode", "auto");
            bool force = HasFlag(args, "--force");
            bool replace = HasFlag(args, "--replace");
            StringBuilder log = new StringBuilder();
            object gate = new object();

            Action<string> write = delegate(string s)
            {
                lock (gate) { log.AppendLine(s); }
            };

            try
            {
                if (!File.Exists(input) && !Directory.Exists(input)) { write("BAD_INPUT " + input); File.WriteAllText(logPath, log.ToString()); return; }
                string mode;
                if (Directory.Exists(input)) mode = "dir";
                else if (input.EndsWith(".zip", StringComparison.OrdinalIgnoreCase)) mode = "zip";
                else mode = "file";

                if (output.Length == 0)
                {
                    if (mode == "file") output = Path.Combine(Path.GetDirectoryName(input), Path.GetFileNameWithoutExtension(input) + ".chartpack");
                    else if (mode == "zip") output = Path.GetDirectoryName(input);
                    else output = input;
                }
                if (mode == "file")
                {
                    if (Directory.Exists(output)) output = Path.Combine(output, Path.GetFileNameWithoutExtension(input) + ".chartpack");
                    if (!output.EndsWith(".chartpack", StringComparison.OrdinalIgnoreCase)) output += ".chartpack";
                }
                else
                {
                    Directory.CreateDirectory(output);
                }

                string version;
                string node = NodeHelper.Ensure(null, out version);
                if (node == null) { write("NODE_MISSING"); File.WriteAllText(logPath, log.ToString()); Environment.ExitCode = 2; return; }
                string script = ScriptProvider.GetScriptPath();
                string cmdArgs = Commands.Build(mode, input, output, jobs, timeMode, force, replace);
                write("NODE " + node);
                write("VERSION " + version);
                write("SCRIPT " + script);
                write("ARGS " + cmdArgs);
                write("OUT " + output);

                PackRunner runner = new PackRunner();
                ManualResetEvent done = new ManualResetEvent(false);
                int exitCode = -1;
                runner.EventReceived += delegate(Dictionary<string, object> d)
                {
                    string ev = Ui.GetStr(d, "event", "");
                    if (ev == "file-done")
                        write("DONE " + Ui.GetStr(d, "name", "?") + " out=" + Ui.GetStr(d, "outBytes", "?") + " notes=" + Ui.GetStr(d, "notes", "?"));
                    else if (ev == "file-error")
                        write("ERROR " + Ui.GetStr(d, "name", "?") + " " + Ui.GetStr(d, "error", "?"));
                    else if (ev == "summary")
                        write("SUMMARY " + Ui.GetStr(d, "totalBytes", "?") + " " + Ui.GetStr(d, "totalOut", "?") + " " + Ui.GetStr(d, "elapsedMs", "?"));
                };
                runner.LogReceived += delegate(string line, bool err) { write((err ? "ERR " : "OUT ") + line); };
                runner.ProcessExited += delegate(int code) { exitCode = code; done.Set(); };
                runner.Start(node, script, cmdArgs);
                if (!done.WaitOne(300000))
                {
                    try { runner.Stop(); } catch { }
                    write("TIMEOUT");
                }
                write("EXIT " + exitCode);
                Environment.ExitCode = exitCode;
            }
            catch (Exception ex)
            {
                write("EXCEPTION " + ex.ToString());
                Environment.ExitCode = 3;
            }
            finally
            {
                try { File.WriteAllText(logPath, log.ToString(), Encoding.UTF8); } catch { }
            }
        }

        [STAThread]
        private static void Main(string[] args)
        {
            try { Run(args); }
            catch (Exception ex)
            {
                try { File.WriteAllText(Path.Combine(AppPaths.Dir, "ui-crash.txt"), ex.ToString()); } catch { }
            }
        }

        private static void Run(string[] args)
        {
            try { SetProcessDPIAware(); } catch { }
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);

            if (args.Length >= 2 && args[0] == "--selftest")
            {
                SelfTest(args[1]);
                return;
            }

            if (args.Length >= 1 && args[0] == "--run")
            {
                RunHeadless(args);
                return;
            }

            if (args.Length >= 1 && args[0] == "--auto")
            {
                string autoIn = args.Length > 1 ? args[1] : "";
                string autoOut = args.Length > 2 ? args[2] : "";
                using (MainForm f = new MainForm())
                {
                    f.Prefill(autoIn, autoOut);
                    f.Shown += delegate
                    {
                        System.Windows.Forms.Timer t = new System.Windows.Forms.Timer();
                        t.Interval = 500;
                        t.Tick += delegate
                        {
                            t.Stop();
                            f.StartFromCommandLine();
                        };
                        t.Start();
                    };
                    Application.Run(f);
                }
                return;
            }

            if (args.Length >= 1 && args[0] == "--demo")
            {
                using (MainForm f = new MainForm())
                {
                    f.SeedDemo();
                    Application.Run(f);
                }
                return;
            }

            if (args.Length >= 2 && args[0] == "--screenshot")
            {
                using (MainForm f = new MainForm())
                {
                    f.SeedDemo();
                    f.StartPosition = FormStartPosition.Manual;
                    f.Location = new Point(-3000, -3000);
                    f.Show();
                    Application.DoEvents();
                    Bitmap bmp = new Bitmap(f.Width, f.Height);
                    f.DrawToBitmap(bmp, new Rectangle(0, 0, f.Width, f.Height));
                    bmp.Save(args[1], ImageFormat.Png);
                    bmp.Dispose();
                    f.Close();
                }
                return;
            }

            Application.Run(new MainForm());
        }
    }
}
