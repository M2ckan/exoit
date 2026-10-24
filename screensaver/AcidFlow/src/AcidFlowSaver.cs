// AcidFlow screensaver host for Windows.
// Wraps AcidFlow.html in a WebView2 (Edge Chromium) window and implements the
// standard screensaver protocol (/s run, /c configure, /p <hwnd> preview).
//
// Everything it needs (WebView2 managed assemblies, native loader, the HTML)
// is embedded as resources and extracted to %LOCALAPPDATA%\AcidFlow on start,
// so the .scr is a single self-contained file. Requires .NET Framework 4.8
// (built into Windows 10/11) and the WebView2 Runtime (ships with Windows 11,
// installed by Edge / Office on Windows 10).
//
// Settings: %LOCALAPPDATA%\AcidFlow\settings.json (created from the embedded template on first run).
// Build: see build.sh (mono mcs) or build.ps1 (csc.exe from the .NET Framework).

using System;
using System.Diagnostics;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using System.Windows.Forms;
using Microsoft.Win32;

[assembly: AssemblyTitle("AcidFlow")]
[assembly: AssemblyDescription("AcidFlow screensaver")]
[assembly: AssemblyProduct("AcidFlow")]
[assembly: AssemblyVersion("1.3.1.0")]
[assembly: AssemblyFileVersion("1.3.1.0")]

namespace AcidFlow
{
    internal static class Settings
    {
        private const string KeyPath = @"Software\AcidFlow";

        public static bool Debug
        {
            get { return Read("Debug", 0) == 1; }
        }

        private static int Read(string name, int def)
        {
            try
            {
                using (RegistryKey k = Registry.CurrentUser.OpenSubKey(KeyPath))
                {
                    if (k == null) return def;
                    object v = k.GetValue(name);
                    return v is int ? (int)v : def;
                }
            }
            catch { return def; }
        }

    }

    internal static class Log
    {
        private static readonly object Gate = new object();
        public static string Path
        {
            get { return System.IO.Path.Combine(Runtime.BaseDir, "AcidFlow.log"); }
        }

        public static void Write(string msg)
        {
            try
            {
                lock (Gate)
                {
                    Directory.CreateDirectory(Runtime.BaseDir);
                    File.AppendAllText(Path, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "  " + msg + Environment.NewLine);
                }
            }
            catch { }
        }
    }

    // Extracts embedded resources and wires up assembly / native DLL resolution.
    internal static class Runtime
    {
        public static readonly string BaseDir =
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "AcidFlow");

        public static string BinDir
        {
            get
            {
                Version v = Assembly.GetExecutingAssembly().GetName().Version;
                return Path.Combine(BaseDir, "bin-" + v.ToString(4));
            }
        }

        public static string UserDataDir { get { return Path.Combine(BaseDir, "WebView2"); } }
        public static string HtmlPath { get { return Path.Combine(BinDir, "AcidFlow.html"); } }
        public static string SettingsPath { get { return Path.Combine(BaseDir, "settings.json"); } }

        // Writes the default settings.json (only if missing, or when reset is requested).
        public static void EnsureSettings(bool reset)
        {
            Directory.CreateDirectory(BaseDir);
            if (File.Exists(SettingsPath) && !reset) return;
            using (Stream s = Assembly.GetExecutingAssembly().GetManifestResourceStream("settings.json"))
            using (FileStream f = new FileStream(SettingsPath, FileMode.Create, FileAccess.Write, FileShare.None))
            {
                if (s == null) throw new FileNotFoundException("Embedded resource missing: settings.json");
                s.CopyTo(f);
            }
        }

        public static string ReadSettingsText()
        {
            try { return File.Exists(SettingsPath) ? File.ReadAllText(SettingsPath) : null; }
            catch (Exception ex) { Log.Write("Could not read settings.json: " + ex.Message); return null; }
        }

        // Escapes text as a JavaScript string literal.
        public static string JsString(string text)
        {
            var sb = new System.Text.StringBuilder(text.Length + 16);
            sb.Append('"');
            foreach (char c in text)
            {
                switch (c)
                {
                    case '\\': sb.Append("\\\\"); break;
                    case '"': sb.Append("\\\""); break;
                    case '\n': sb.Append("\\n"); break;
                    case '\r': sb.Append("\\r"); break;
                    case '\t': sb.Append("\\t"); break;
                    case '\u2028': sb.Append("\\u2028"); break;
                    case '\u2029': sb.Append("\\u2029"); break;
                    case '<': sb.Append("\\u003c"); break;
                    default:
                        if (c < ' ') sb.AppendFormat("\\u{0:x4}", (int)c); else sb.Append(c);
                        break;
                }
            }
            sb.Append('"');
            return sb.ToString();
        }

        private static readonly string[] Resources =
        {
            "Microsoft.Web.WebView2.Core.dll",
            "Microsoft.Web.WebView2.WinForms.dll",
            "WebView2Loader.dll",
            "AcidFlow.html",
        };

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool SetDllDirectory(string path);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr LoadLibrary(string path);

        public static void Prepare()
        {
            Directory.CreateDirectory(BinDir);
            EnsureSettings(false);
            Assembly self = Assembly.GetExecutingAssembly();
            foreach (string name in Resources)
            {
                string target = Path.Combine(BinDir, name);
                using (Stream s = self.GetManifestResourceStream(name))
                {
                    if (s == null) throw new FileNotFoundException("Embedded resource missing: " + name);
                    FileInfo fi = new FileInfo(target);
                    if (fi.Exists && fi.Length == s.Length) continue;
                    using (FileStream f = new FileStream(target, FileMode.Create, FileAccess.Write, FileShare.None))
                    {
                        s.CopyTo(f);
                    }
                }
            }

            // Managed WebView2 assemblies resolve from the extraction folder.
            AppDomain.CurrentDomain.AssemblyResolve += (sender, args) =>
            {
                string simple = new AssemblyName(args.Name).Name;
                string candidate = Path.Combine(BinDir, simple + ".dll");
                return File.Exists(candidate) ? Assembly.LoadFrom(candidate) : null;
            };

            // Native loader: make sure the x64 copy next to the assemblies is the one that gets picked up.
            try
            {
                SetDllDirectory(BinDir);
                IntPtr h = LoadLibrary(Path.Combine(BinDir, "WebView2Loader.dll"));
                if (h == IntPtr.Zero) Log.Write("LoadLibrary(WebView2Loader.dll) failed, error " + Marshal.GetLastWin32Error());
            }
            catch (Exception ex) { Log.Write("Native loader setup failed: " + ex.Message); }
        }
    }

    internal static class Native
    {
        public const int WH_KEYBOARD_LL = 13;
        public const int WH_MOUSE_LL = 14;
        public const int WM_MOUSEMOVE = 0x0200;
        public const int WM_POWERBROADCAST = 0x0218;
        public const int PBT_POWERSETTINGCHANGE = 0x8013;
        public const int GWL_STYLE = -16;
        public const int WS_CHILD = 0x40000000;
        public const int DEVICE_NOTIFY_WINDOW_HANDLE = 0;

        public static readonly Guid GUID_CONSOLE_DISPLAY_STATE = new Guid("6fe69556-704a-47a0-8f24-c28d936fda47");

        public delegate IntPtr HookProc(int nCode, IntPtr wParam, IntPtr lParam);

        [StructLayout(LayoutKind.Sequential)]
        public struct POINT { public int x; public int y; }

        [StructLayout(LayoutKind.Sequential)]
        public struct MSLLHOOKSTRUCT
        {
            public POINT pt; public uint mouseData; public uint flags; public uint time; public IntPtr dwExtraInfo;
        }

        [StructLayout(LayoutKind.Sequential, Pack = 4)]
        public struct POWERBROADCAST_SETTING
        {
            public Guid PowerSetting; public uint DataLength; public byte Data;
        }

        [DllImport("user32.dll", SetLastError = true)] public static extern IntPtr SetWindowsHookEx(int idHook, HookProc lpfn, IntPtr hMod, uint dwThreadId);
        [DllImport("user32.dll")] public static extern bool UnhookWindowsHookEx(IntPtr hhk);
        [DllImport("user32.dll")] public static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr GetModuleHandle(string lpModuleName);
        [DllImport("user32.dll")] public static extern IntPtr SetParent(IntPtr hWndChild, IntPtr hWndNewParent);
        [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
        [DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
        [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr hWnd, out RECT lpRect);
        [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hWnd);
        [DllImport("user32.dll")] public static extern IntPtr RegisterPowerSettingNotification(IntPtr hRecipient, ref Guid PowerSettingGuid, int Flags);
        [DllImport("user32.dll")] public static extern bool UnregisterPowerSettingNotification(IntPtr handle);
        [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
        [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
        [DllImport("user32.dll")] public static extern int ShowCursor(bool bShow);

        [StructLayout(LayoutKind.Sequential)]
        public struct RECT { public int Left, Top, Right, Bottom; }

        public static void EnableDpiAwareness()
        {
            try
            {
                // DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 == -4 (Windows 10 1703+)
                if (!SetProcessDpiAwarenessContext(new IntPtr(-4))) SetProcessDPIAware();
            }
            catch { try { SetProcessDPIAware(); } catch { } }
        }
    }

    internal enum Mode { Run, Preview, Configure }

    internal sealed class SaverForm : Form
    {
        private readonly Mode _mode;
        private readonly IntPtr _previewParent;
        private Microsoft.Web.WebView2.WinForms.WebView2 _web;
        private IntPtr _mouseHook = IntPtr.Zero, _kbHook = IntPtr.Zero;
        private Native.HookProc _mouseProc, _kbProc;   // keep delegates alive for the hook lifetime
        private Native.POINT _origin; private bool _originSet;
        private readonly Stopwatch _uptime = Stopwatch.StartNew();
        private IntPtr _powerNotify = IntPtr.Zero;
        private Timer _parentWatch;
        private bool _closing;

        public SaverForm(Mode mode, IntPtr previewParent)
        {
            _mode = mode;
            _previewParent = previewParent;
            Text = "AcidFlow";
            BackColor = Color.Black;
            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            StartPosition = FormStartPosition.Manual;
            DoubleBuffered = true;

            if (mode == Mode.Run)
            {
                Rectangle vs = SystemInformation.VirtualScreen;
                Bounds = vs;
                TopMost = true;
            }
            else
            {
                Native.RECT rc;
                Native.GetClientRect(previewParent, out rc);
                Bounds = new Rectangle(0, 0, Math.Max(1, rc.Right - rc.Left), Math.Max(1, rc.Bottom - rc.Top));
            }
        }

        protected override void OnLoad(EventArgs e)
        {
            base.OnLoad(e);
            if (_mode == Mode.Run)
            {
                Native.ShowCursor(false);
                InstallHooks();
                Guid g = Native.GUID_CONSOLE_DISPLAY_STATE;
                _powerNotify = Native.RegisterPowerSettingNotification(Handle, ref g, Native.DEVICE_NOTIFY_WINDOW_HANDLE);
                SystemEvents.SessionSwitch += OnSessionSwitch;
            }
            else
            {
                // embed in the settings dialog's preview window
                int style = Native.GetWindowLong(Handle, Native.GWL_STYLE);
                Native.SetWindowLong(Handle, Native.GWL_STYLE, style | Native.WS_CHILD);
                Native.SetParent(Handle, _previewParent);
                Native.RECT rc;
                Native.GetClientRect(_previewParent, out rc);
                Bounds = new Rectangle(0, 0, Math.Max(1, rc.Right - rc.Left), Math.Max(1, rc.Bottom - rc.Top));
                _parentWatch = new Timer { Interval = 1000 };
                _parentWatch.Tick += (s, a) => { if (!Native.IsWindow(_previewParent)) Shutdown(); };
                _parentWatch.Start();
            }
            StartWebView();
        }

        private async void StartWebView()
        {
            try
            {
                await InitWebView();
            }
            catch (Exception ex)
            {
                Log.Write("WebView2 init failed: " + ex);
                if (_mode == Mode.Run) Shutdown();
            }
        }

        private async Task InitWebView()
        {
            _web = new Microsoft.Web.WebView2.WinForms.WebView2
            {
                Dock = DockStyle.Fill,
                DefaultBackgroundColor = Color.Black,
            };
            Controls.Add(_web);

            var options = new Microsoft.Web.WebView2.Core.CoreWebView2EnvironmentOptions(
                "--disable-features=msSmartScreenProtection,msEdgeShoppingFeature --autoplay-policy=no-user-gesture-required");
            var env = await Microsoft.Web.WebView2.Core.CoreWebView2Environment.CreateAsync(null, Runtime.UserDataDir, options);
            if (_closing) return;
            await _web.EnsureCoreWebView2Async(env);
            if (_closing) return;

            var core = _web.CoreWebView2;
            core.Settings.AreDefaultContextMenusEnabled = false;
            core.Settings.AreDevToolsEnabled = Settings.Debug;
            core.Settings.IsStatusBarEnabled = false;
            core.Settings.IsZoomControlEnabled = false;
            core.Settings.AreBrowserAcceleratorKeysEnabled = false;
            core.Settings.IsPinchZoomEnabled = false;
            core.Settings.IsSwipeNavigationEnabled = false;
            core.Settings.AreDefaultScriptDialogsEnabled = false;

            // settings.json is handed to the page verbatim; the page parses it (comments allowed) and
            // falls back to its defaults on errors, which it reports on the console.
            string settingsText = Runtime.ReadSettingsText();
            if (settingsText != null)
                await core.AddScriptToExecuteOnDocumentCreatedAsync("window.ACID_SETTINGS_TEXT = " + Runtime.JsString(settingsText) + ";");
            if (_closing) return;

            string url = new Uri(Runtime.HtmlPath).AbsoluteUri + "?saver=1";
            if (_mode == Mode.Preview) url += "&fps=20&maxscale=0.5&scale=0.5";
            Log.Write("Navigate " + url);
            core.Navigate(url);
        }

        // ---- input detection (global low-level hooks so the WebView's own HWND cannot swallow events)
        private void InstallHooks()
        {
            _mouseProc = MouseHook;
            _kbProc = KeyboardHook;
            IntPtr mod = Native.GetModuleHandle(null);
            _mouseHook = Native.SetWindowsHookEx(Native.WH_MOUSE_LL, _mouseProc, mod, 0);
            _kbHook = Native.SetWindowsHookEx(Native.WH_KEYBOARD_LL, _kbProc, mod, 0);
            if (_mouseHook == IntPtr.Zero || _kbHook == IntPtr.Zero)
                Log.Write("Hook install failed, error " + Marshal.GetLastWin32Error());
        }

        private IntPtr MouseHook(int nCode, IntPtr wParam, IntPtr lParam)
        {
            if (nCode >= 0 && !_closing)
            {
                int msg = wParam.ToInt32();
                if (msg == Native.WM_MOUSEMOVE)
                {
                    var info = (Native.MSLLHOOKSTRUCT)Marshal.PtrToStructure(lParam, typeof(Native.MSLLHOOKSTRUCT));
                    if (!_originSet) { _origin = info.pt; _originSet = true; }
                    else
                    {
                        int dx = Math.Abs(info.pt.x - _origin.x), dy = Math.Abs(info.pt.y - _origin.y);
                        // ignore sub-pixel jitter and anything in the first second (WebView startup can nudge the cursor)
                        if ((dx > 8 || dy > 8) && _uptime.ElapsedMilliseconds > 1000) Shutdown();
                    }
                }
                else if (_uptime.ElapsedMilliseconds > 500)
                {
                    Shutdown();   // any button / wheel
                }
            }
            return Native.CallNextHookEx(_mouseHook, nCode, wParam, lParam);
        }

        private IntPtr KeyboardHook(int nCode, IntPtr wParam, IntPtr lParam)
        {
            if (nCode >= 0 && !_closing && _uptime.ElapsedMilliseconds > 500) Shutdown();
            return Native.CallNextHookEx(_kbHook, nCode, wParam, lParam);
        }

        private void OnSessionSwitch(object sender, SessionSwitchEventArgs e)
        {
            if (e.Reason == SessionSwitchReason.SessionLock || e.Reason == SessionSwitchReason.ConsoleDisconnect ||
                e.Reason == SessionSwitchReason.RemoteDisconnect) Shutdown();
        }

        // ---- pause rendering while the display is powered off so a dark monitor costs nothing
        protected override void WndProc(ref Message m)
        {
            if (m.Msg == Native.WM_POWERBROADCAST && m.WParam.ToInt32() == Native.PBT_POWERSETTINGCHANGE && m.LParam != IntPtr.Zero)
            {
                try
                {
                    var s = (Native.POWERBROADCAST_SETTING)Marshal.PtrToStructure(m.LParam, typeof(Native.POWERBROADCAST_SETTING));
                    if (s.PowerSetting == Native.GUID_CONSOLE_DISPLAY_STATE)
                    {
                        bool displayOn = s.Data != 0;   // 0 = off, 1 = on, 2 = dimmed
                        Log.Write("Display state: " + s.Data);
                        SetPaused(!displayOn);
                    }
                }
                catch (Exception ex) { Log.Write("Power notification error: " + ex.Message); }
            }
            base.WndProc(ref m);
        }

        private async void SetPaused(bool paused)
        {
            try
            {
                if (_web != null && _web.CoreWebView2 != null)
                    await _web.CoreWebView2.ExecuteScriptAsync("window.__acidPause && window.__acidPause(" + (paused ? "true" : "false") + ")");
            }
            catch (Exception ex) { Log.Write("SetPaused error: " + ex.Message); }
        }

        private void Shutdown()
        {
            if (_closing) return;
            _closing = true;
            if (InvokeRequired) { try { BeginInvoke((Action)Shutdown); } catch { } return; }
            try { Close(); } catch { }
        }

        protected override void OnFormClosed(FormClosedEventArgs e)
        {
            _closing = true;
            if (_mouseHook != IntPtr.Zero) Native.UnhookWindowsHookEx(_mouseHook);
            if (_kbHook != IntPtr.Zero) Native.UnhookWindowsHookEx(_kbHook);
            if (_powerNotify != IntPtr.Zero) Native.UnregisterPowerSettingNotification(_powerNotify);
            if (_mode == Mode.Run) { SystemEvents.SessionSwitch -= OnSessionSwitch; Native.ShowCursor(true); }
            if (_parentWatch != null) _parentWatch.Dispose();
            try { if (_web != null) _web.Dispose(); } catch { }
            base.OnFormClosed(e);
            Application.Exit();
        }
    }

    internal sealed class ConfigForm : Form
    {
        public ConfigForm()
        {
            Text = "AcidFlow settings";
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false; MinimizeBox = false;
            StartPosition = FormStartPosition.CenterScreen;
            AutoScaleMode = AutoScaleMode.Dpi;
            ClientSize = new Size(440, 250);
            Font = SystemFonts.MessageBoxFont;

            var info = new Label
            {
                Left = 16, Top = 16, Width = 408, Height = 120,
                Text = "All settings (frame rate cap, quality, speed, colours, palettes, line shapes) live in a text file:\n\n"
                     + Runtime.SettingsPath + "\n\n"
                     + "Every key is documented inline. Changes apply the next time the screensaver starts. "
                     + "Rendering pauses automatically while the display is powered off.",
            };
            var btnEdit = new Button { Text = "Edit settings...", Left = 16, Top = 150, Width = 130 };
            var btnReset = new Button { Text = "Reset to defaults", Left = 154, Top = 150, Width = 130 };
            var btnLog = new Button { Text = "Open log", Left = 292, Top = 150, Width = 132 };
            var close = new Button { Text = "Close", Left = 348, Top = 206, Width = 76, DialogResult = DialogResult.OK };

            btnEdit.Click += (s, e) =>
            {
                try { Runtime.EnsureSettings(false); Process.Start("notepad.exe", "\"" + Runtime.SettingsPath + "\""); }
                catch (Exception ex) { MessageBox.Show(this, ex.Message, "AcidFlow", MessageBoxButtons.OK, MessageBoxIcon.Error); }
            };
            btnReset.Click += (s, e) =>
            {
                if (MessageBox.Show(this, "Overwrite settings.json with the defaults?", "AcidFlow", MessageBoxButtons.YesNo, MessageBoxIcon.Question) != DialogResult.Yes) return;
                try { Runtime.EnsureSettings(true); }
                catch (Exception ex) { MessageBox.Show(this, ex.Message, "AcidFlow", MessageBoxButtons.OK, MessageBoxIcon.Error); }
            };
            btnLog.Click += (s, e) =>
            {
                try { if (File.Exists(Log.Path)) Process.Start("notepad.exe", "\"" + Log.Path + "\""); else MessageBox.Show(this, "No log yet.", "AcidFlow"); }
                catch (Exception ex) { MessageBox.Show(this, ex.Message, "AcidFlow", MessageBoxButtons.OK, MessageBoxIcon.Error); }
            };
            AcceptButton = close; CancelButton = close;
            Controls.AddRange(new Control[] { info, btnEdit, btnReset, btnLog, close });
        }
    }

    internal static class Program
    {
        [STAThread]
        private static int Main(string[] args)
        {
            Native.EnableDpiAwareness();
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            AppDomain.CurrentDomain.UnhandledException += (s, e) => Log.Write("Unhandled: " + e.ExceptionObject);
            Application.ThreadException += (s, e) => { Log.Write("UI thread exception: " + e.Exception); Application.Exit(); };

            Mode mode = Mode.Configure;
            IntPtr hwnd = IntPtr.Zero;
            if (args.Length > 0)
            {
                string a = args[0].Trim().ToLowerInvariant();
                string rest = a.Length > 2 ? a.Substring(2).TrimStart(':', ' ') : (args.Length > 1 ? args[1] : "");
                if (a.StartsWith("/s") || a.StartsWith("-s")) mode = Mode.Run;
                else if (a.StartsWith("/p") || a.StartsWith("-p")) { mode = Mode.Preview; long h; if (long.TryParse(rest, out h)) hwnd = new IntPtr(h); }
                else mode = Mode.Configure;   // /c, /c:hwnd, or anything else
            }

            if (mode == Mode.Configure)
            {
                try { Runtime.EnsureSettings(false); } catch (Exception ex) { Log.Write("EnsureSettings failed: " + ex); }
                Application.Run(new ConfigForm());
                return 0;
            }
            if (mode == Mode.Preview && hwnd == IntPtr.Zero) return 0;

            try { Runtime.Prepare(); }
            catch (Exception ex) { Log.Write("Prepare failed: " + ex); return 1; }

            return RunSaver(mode, hwnd);
        }

        // Separate method so the JIT does not touch WebView2 types before AssemblyResolve is wired up.
        private static int RunSaver(Mode mode, IntPtr hwnd)
        {
            try
            {
                Application.Run(new SaverForm(mode, hwnd));
                return 0;
            }
            catch (Exception ex)
            {
                Log.Write("Fatal: " + ex);
                return 1;
            }
        }
    }
}
