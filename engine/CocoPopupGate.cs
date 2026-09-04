using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public class CocoPopupGate {
    private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    private delegate void WinEventProc(IntPtr hHook, uint evt, IntPtr hwnd, long idObject, long idChild, uint dwEventThread, uint dwmsEventTime);

    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowsProc enumProc, IntPtr lParam);
    [DllImport("user32.dll")] private static extern bool EnumChildWindows(IntPtr hWndParent, EnumWindowsProc enumProc, IntPtr lParam);
    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)] private static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);
    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)] private static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern bool IsWindow(IntPtr hWnd);
    [DllImport("user32.dll", CharSet = CharSet.Auto)] private static extern IntPtr SendMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Auto)] private static extern IntPtr PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("user32.dll")] private static extern int GetSystemMetrics(int nIndex);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern IntPtr CreateToolhelp32Snapshot(uint dwFlags, uint th32ProcessID);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)] private static extern bool Process32FirstW(IntPtr hSnapshot, ref PROCESSENTRY32W lppe);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)] private static extern bool Process32NextW(IntPtr hSnapshot, ref PROCESSENTRY32W lppe);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool CloseHandle(IntPtr hObject);
    [DllImport("user32.dll")] private static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] private static extern IntPtr SetWinEventHook(uint eventMin, uint eventMax, IntPtr hmodWinEventProc, WinEventProc pfnWinEventProc, uint idProcess, uint idThread, uint dwFlags);
    [DllImport("user32.dll")] private static extern bool UnhookWinEvent(IntPtr hWinEventHook);
    [DllImport("user32.dll")] private static extern int GetMessage(out NativeMessage lpMsg, IntPtr hWnd, uint wMsgFilterMin, uint wMsgFilterMax);
    [DllImport("user32.dll")] private static extern bool PostThreadMessage(uint idThread, uint msg, IntPtr wParam, IntPtr lParam);
    [DllImport("kernel32.dll")] private static extern uint GetCurrentThreadId();
    [DllImport("shcore.dll")] private static extern int SetProcessDpiAwareness(int awareness);
    [DllImport("user32.dll")] private static extern bool SetProcessDPIAware();
    [DllImport("uxtheme.dll", ExactSpelling = true, CharSet = CharSet.Unicode)] public static extern int SetWindowTheme(IntPtr hWnd, string pszSubAppName, string pszSubIdList);

    public static void EnablePerMonitorDpi() {
        try { if (SetProcessDpiAwareness(2) == 0) return; } catch {}
        try { SetProcessDPIAware(); } catch {}
    }

    public static void ApplyDarkTheme(IntPtr hWnd) {
        try { SetWindowTheme(hWnd, "DarkMode_Explorer", null); } catch {}
    }

    [StructLayout(LayoutKind.Sequential)] private struct NativeMessage { public IntPtr handle; public uint message; public IntPtr wParam; public IntPtr lParam; public uint time; public int ptX; public int ptY; }
    private const uint EVENT_OBJECT_SHOW = 0x8002;
    private const uint WINEVENT_OUTOFCONTEXT = 0x00000000;
    private const uint WM_QUIT = 0x0012;
    private const int SW_HIDE = 0;
    private const int SW_SHOW = 5;
    private const long OBJID_WINDOW = 0;

    [StructLayout(LayoutKind.Sequential)] private struct RECT { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct PROCESSENTRY32W {
        public uint dwSize; public uint cntUsage; public uint th32ProcessID; public IntPtr th32DefaultHeapID;
        public uint th32ModuleID; public uint cntThreads; public uint th32ParentProcessID; public int pcPriClassBase; public uint dwFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szExeFile;
    }

    private const uint TH32CS_SNAPPROCESS = 0x00000002;
    private const uint WM_CLOSE = 0x0010;
    private const uint WM_COMMAND = 0x0111;
    private const uint BM_CLICK = 0x00F5;
    private const int IDOK = 1;

    private static Thread worker;
    private static Thread hookThread;
    private static uint hookThreadId;
    private static IntPtr eventHook;
    private static readonly object treeLock = new object();
    private static HashSet<int> treeCache = new HashSet<int>();
    private static readonly Dictionary<long, DateTime> clickedPending = new Dictionary<long, DateTime>();
    private static volatile bool running;
    private static int generation;
    private static int rootPid;
    private static string[] markers = new string[0];
    private static string[] labels = new string[0];
    private static string[] dialogClasses = new string[0];
    private static string[] browserNames = new string[0];
    private static readonly Dictionary<long, DateTime> actedOn = new Dictionary<long, DateTime>();
    private static readonly List<string> diagnostics = new List<string>();
    private static readonly HashSet<int> baselineBrowserPids = new HashSet<int>();
    private static DateTime startedUtc = DateTime.UtcNow;

    public static long ClickedCount;
    public static long ClosedCount;
    public static long HiddenCount;
    public static string LastAction = "";
    private static readonly WinEventProc winEventHandler = new WinEventProc(OnWindowShown);

    public static bool IsRunning() { return running; }

    public static void BindProcessId(int pid) {
        rootPid = pid;
        lock (treeLock) {
            if (treeCache == null) treeCache = new HashSet<int>();
            if (pid != 0) treeCache.Add(pid);
        }
    }

    private static void HookThreadLoop(int myGeneration) {
        try {
            hookThreadId = GetCurrentThreadId();
            eventHook = SetWinEventHook(EVENT_OBJECT_SHOW, EVENT_OBJECT_SHOW, IntPtr.Zero, winEventHandler, 0, 0, WINEVENT_OUTOFCONTEXT);
            NativeMessage msg;
            while (running && myGeneration == generation) {
                int result = GetMessage(out msg, IntPtr.Zero, 0, 0);
                if (result <= 0) break;
            }
        } catch {}
        finally {
            if (eventHook != IntPtr.Zero) { try { UnhookWinEvent(eventHook); } catch {} eventHook = IntPtr.Zero; }
        }
    }

    private static void OnWindowShown(IntPtr hHook, uint evt, IntPtr hwnd, long idObject, long idChild, uint eventThread, uint eventTimeMs) {
        try {
            if (idObject != OBJID_WINDOW || hwnd == IntPtr.Zero || !IsWindow(hwnd) || !IsWindowVisible(hwnd)) return;
            HashSet<int> pids;
            lock (treeLock) { pids = treeCache; }
            uint pid;
            GetWindowThreadProcessId(hwnd, out pid);
            int managedPid = unchecked((int)pid);
            bool inTree = rootPid != 0 && managedPid == rootPid;
            if (!inTree && pids != null && pids.Count > 0) inTree = pids.Contains(managedPid);
            else if (!inTree && pids != null && pids.Count == 0 && rootPid != 0) { inTree = CollectTreePids(rootPid).Contains(managedPid); }
            if (!inTree) {
                if ((DateTime.UtcNow - startedUtc).TotalSeconds < 90) {
                    StringBuilder t = new StringBuilder(512);
                    GetWindowText(hwnd, t, 512);
                    string tStr = (t.ToString() ?? "").ToLowerInvariant();
                    bool hit = false;
                    foreach (string rm in redirectTitleMarkers) {
                        if (tStr.Contains(rm)) { hit = true; break; }
                    }
                    if (hit) {
                        ShowWindow(hwnd, SW_HIDE);
                        PostMessage(hwnd, WM_CLOSE, IntPtr.Zero, IntPtr.Zero);
                        LastAction = "hook-close-redirect-win:" + tStr;
                    }
                }
                return;
            }
            WindowInfo info = new WindowInfo();
            info.Handle = hwnd;
            info.Pid = pid;
            StringBuilder cls = new StringBuilder(256);
            GetClassName(hwnd, cls, 256);
            info.Class = cls.ToString();
            StringBuilder title = new StringBuilder(512);
            GetWindowText(hwnd, title, 512);
            info.Title = title.ToString();
            RECT rect;
            if (GetWindowRect(hwnd, out rect)) info.Area = (long)Math.Max(0, rect.Right - rect.Left) * Math.Max(0, rect.Bottom - rect.Top);
            CollectChildren(info);
            TryAct(info);
        } catch {}
    }

    public static void StartSessionWatcher(int pid, string markersCsv, string labelsCsv, string dialogsCsv, string browsersCsv = "") {
        Thread oldWorker = worker;
        if (oldWorker != null && oldWorker.IsAlive) {
            running = false;
            try { oldWorker.Join(2500); } catch {}
        }
        Thread oldHook = hookThread;
        if (oldHook != null && oldHook.IsAlive && hookThreadId != 0) {
            try { PostThreadMessage(hookThreadId, WM_QUIT, IntPtr.Zero, IntPtr.Zero); } catch {}
            try { oldHook.Join(1500); } catch {}
        }
        markers = SplitCsv(markersCsv);
        labels = SplitCsv(labelsCsv);
        dialogClasses = SplitCsv(dialogsCsv);
        if (!string.IsNullOrEmpty(browsersCsv)) {
            browserNames = SplitCsv(browsersCsv);
        } else {
            browserNames = defaultBrowsers;
        }
        rootPid = pid;
        startedUtc = DateTime.UtcNow;
        lock (diagnostics) { diagnostics.Clear(); }
        actedOn.Clear();
        clickedPending.Clear();
        lock (treeLock) { treeCache = new HashSet<int>(); if (pid != 0) treeCache.Add(pid); }
        lock (baselineBrowserPids) {
            baselineBrowserPids.Clear();
            foreach (int p in SnapshotBrowserPids()) baselineBrowserPids.Add(p);
        }
        ClickedCount = 0; ClosedCount = 0; HiddenCount = 0; LastAction = "";
        int currentGeneration = ++generation;
        running = true;
        hookThread = new Thread(delegate() { HookThreadLoop(currentGeneration); });
        hookThread.IsBackground = true;
        hookThread.Start();
        worker = new Thread(delegate() { Loop(currentGeneration); });
        worker.IsBackground = true;
        worker.Start();
    }

    public static void StopSessionWatcher() {
        running = false;
        if (hookThreadId != 0) { try { PostThreadMessage(hookThreadId, WM_QUIT, IntPtr.Zero, IntPtr.Zero); } catch {} }
    }

    public static string Describe() {
        return "clics=" + ClickedCount.ToString() + ";cierres=" + ClosedCount.ToString() + ";ocultaciones=" + HiddenCount.ToString() + ";ultimo=" + (LastAction == null ? "" : LastAction);
    }

    public static string TakeDiagnostics() {
        lock (diagnostics) {
            if (diagnostics.Count == 0) return "";
            string joined = string.Join(" ;; ", diagnostics.ToArray());
            diagnostics.Clear();
            return joined;
        }
    }

    private static string[] SplitCsv(string value) {
        if (string.IsNullOrEmpty(value)) return new string[0];
        string[] parts = value.Split('|');
        List<string> kept = new List<string>();
        foreach (string part in parts) {
            string trimmed = part.Trim();
            if (trimmed.Length > 0) kept.Add(trimmed.ToLowerInvariant());
        }
        return kept.ToArray();
    }

    private static bool IsPidAlive(int pid) {
        if (pid == 0) return true;
        try {
            Process probe = Process.GetProcessById(pid);
            return probe != null && !probe.HasExited;
        } catch { return false; }
    }

    private static HashSet<int> CollectTreePids(int root) {
        HashSet<int> result = new HashSet<int>();
        result.Add(root);
        Dictionary<int, List<int>> children = new Dictionary<int, List<int>>();
        IntPtr snapshot = IntPtr.Zero;
        try {
            snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
            if (snapshot != IntPtr.Zero && snapshot != (IntPtr)(-1)) {
                PROCESSENTRY32W entry = new PROCESSENTRY32W();
                entry.dwSize = (uint)Marshal.SizeOf(typeof(PROCESSENTRY32W));
                if (Process32FirstW(snapshot, ref entry)) {
                    do {
                        int pid = unchecked((int)entry.th32ProcessID);
                        int parent = unchecked((int)entry.th32ParentProcessID);
                        if (!children.ContainsKey(parent)) children[parent] = new List<int>();
                        children[parent].Add(pid);
                    } while (Process32NextW(snapshot, ref entry));
                }
            }
        } catch {} finally { if (snapshot != IntPtr.Zero && snapshot != (IntPtr)(-1)) CloseHandle(snapshot); }
        Queue<int> pending = new Queue<int>();
        pending.Enqueue(root);
        while (pending.Count > 0) {
            int current = pending.Dequeue();
            List<int> kids;
            if (children.TryGetValue(current, out kids)) {
                foreach (int kid in kids) {
                    if (kid != current && result.Add(kid)) pending.Enqueue(kid);
                }
            }
        }
        return result;
    }

    private static void Loop(int myGeneration) {
        DateTime deadline = DateTime.UtcNow.AddHours(12);
        DateTime treeGoneAt = DateTime.MinValue;
        while (running && myGeneration == generation && DateTime.UtcNow < deadline) {
            try {
                if (!IsPidAlive(rootPid)) {
                    if (treeGoneAt == DateTime.MinValue) treeGoneAt = DateTime.UtcNow;
                    if ((DateTime.UtcNow - treeGoneAt).TotalMilliseconds > 5000) break;
                }
                Sweep();
            } catch {}
            Thread.Sleep(200);
        }
        if (myGeneration == generation) running = false;
    }

    private class WindowInfo {
        public IntPtr Handle;
        public uint Pid;
        public string Class = "";
        public string Title = "";
        public long Area;
        public List<string> ButtonHandlesText = new List<string>();
        public List<IntPtr> ButtonHandles = new List<IntPtr>();
        public List<string> OtherTexts = new List<string>();
    }

    private static readonly string[] defaultBrowsers = new string[] {
        "chrome.exe", "msedge.exe", "firefox.exe", "zen.exe", "arc.exe", "brave.exe", "opera.exe", "opera_gx.exe",
        "iexplore.exe", "browser.exe", "waterfox.exe", "vivaldi.exe", "floorp.exe", "thorium.exe", "librewolf.exe",
        "chromium.exe", "epic.exe", "sidekick.exe", "yandex.exe", "whale.exe", "maxthon.exe"
    };

    private static readonly string[] redirectTitleMarkers = new string[] {
        "online-fix", "onlinefix", "online fix", "ofme", "freesteam", "steamrip", "free steam", "credits", "cr\u00e9ditos", "the fix is made by", "cs.rin.ru"
    };

    private static HashSet<int> SnapshotBrowserPids() {
        HashSet<int> result = new HashSet<int>();
        IntPtr snapshot = IntPtr.Zero;
        try {
            snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
            if (snapshot != IntPtr.Zero && snapshot != (IntPtr)(-1)) {
                PROCESSENTRY32W entry = new PROCESSENTRY32W();
                entry.dwSize = (uint)Marshal.SizeOf(typeof(PROCESSENTRY32W));
                if (Process32FirstW(snapshot, ref entry)) {
                    do {
                        int pid = unchecked((int)entry.th32ProcessID);
                        string exe = (entry.szExeFile ?? "").ToLowerInvariant();
                        foreach (string b in browserNames) {
                            if (exe == b || exe.EndsWith(b)) { result.Add(pid); break; }
                        }
                    } while (Process32NextW(snapshot, ref entry));
                }
            }
        } catch {}
        finally { if (snapshot != IntPtr.Zero && snapshot != (IntPtr)(-1)) CloseHandle(snapshot); }
        return result;
    }

    private static void SuppressRedirectProcesses(HashSet<int> treePids) {
        IntPtr snapshot = IntPtr.Zero;
        try {
            snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
            if (snapshot != IntPtr.Zero && snapshot != (IntPtr)(-1)) {
                PROCESSENTRY32W entry = new PROCESSENTRY32W();
                entry.dwSize = (uint)Marshal.SizeOf(typeof(PROCESSENTRY32W));
                if (Process32FirstW(snapshot, ref entry)) {
                    do {
                        int pid = unchecked((int)entry.th32ProcessID);
                        if (pid != rootPid) {
                            string exe = (entry.szExeFile ?? "").ToLowerInvariant();
                            bool isBrowser = false;
                            foreach (string b in browserNames) {
                                if (exe == b || exe.EndsWith(b)) { isBrowser = true; break; }
                            }
                            if (isBrowser) {
                                bool inTree = treePids != null && treePids.Contains(pid);
                                bool newSpawn = false;
                                lock (baselineBrowserPids) {
                                    newSpawn = (DateTime.UtcNow - startedUtc).TotalSeconds < 75 && !baselineBrowserPids.Contains(pid);
                                }
                                if (inTree || newSpawn) {
                                    try {
                                        Process p = Process.GetProcessById(pid);
                                        p.Kill();
                                        LastAction = "kill-redirect-proc:" + exe + "(" + pid + ")";
                                    } catch {}
                                }
                            }
                        }
                    } while (Process32NextW(snapshot, ref entry));
                }
            }
        } catch {}
        finally { if (snapshot != IntPtr.Zero && snapshot != (IntPtr)(-1)) CloseHandle(snapshot); }
    }

    private static void Sweep() {
        HashSet<int> pids = CollectTreePids(rootPid);
        lock (treeLock) { treeCache = pids; }
        SuppressRedirectProcesses(pids);
        RestoreStuckWindows();
        List<WindowInfo> windows = new List<WindowInfo>();
        EnumWindows(delegate(IntPtr hWnd, IntPtr lParam) {
            try {
                if (!IsWindow(hWnd) || !IsWindowVisible(hWnd)) return true;
                uint pid;
                GetWindowThreadProcessId(hWnd, out pid);
                StringBuilder title = new StringBuilder(512);
                GetWindowText(hWnd, title, 512);
                string titleStr = title.ToString();
                string lowerTitle = titleStr.ToLowerInvariant();

                bool inTree = pids.Contains(unchecked((int)pid));
                if (!inTree && (DateTime.UtcNow - startedUtc).TotalSeconds < 90) {
                    bool isRedirect = false;
                    foreach (string rm in redirectTitleMarkers) {
                        if (lowerTitle.Contains(rm)) { isRedirect = true; break; }
                    }
                    if (isRedirect) {
                        ShowWindow(hWnd, SW_HIDE);
                        PostMessage(hWnd, WM_CLOSE, IntPtr.Zero, IntPtr.Zero);
                        LastAction = "close-redirect-win:" + titleStr;
                        return true;
                    }
                }
                if (!inTree) return true;
                WindowInfo info = new WindowInfo();
                info.Handle = hWnd;
                info.Pid = pid;
                StringBuilder cls = new StringBuilder(256);
                GetClassName(hWnd, cls, 256);
                info.Class = cls.ToString();
                info.Title = titleStr;
                RECT rect;
                if (GetWindowRect(hWnd, out rect)) info.Area = (long)Math.Max(0, rect.Right - rect.Left) * Math.Max(0, rect.Bottom - rect.Top);
                CollectChildren(info);
                windows.Add(info);
            } catch {}
            return true;
        }, IntPtr.Zero);

        foreach (WindowInfo info in windows) { TryAct(info); }
    }

    private static void CollectChildren(WindowInfo info) {
        try {
            EnumChildWindows(info.Handle, delegate(IntPtr child, IntPtr lParam) {
                try {
                    StringBuilder cls = new StringBuilder(256);
                    GetClassName(child, cls, 256);
                    string childClass = cls.ToString();
                    StringBuilder text = new StringBuilder(512);
                    GetWindowText(child, text, 512);
                    string childText = text.ToString();
                    string lowerClass = childClass.ToLowerInvariant();
                    if (lowerClass.Contains("button")) {
                        info.ButtonHandles.Add(child);
                        info.ButtonHandlesText.Add(childText);
                    } else if (info.OtherTexts.Count < 40 && childText.Length > 0 &&
                               (lowerClass.Contains("static") || lowerClass.Contains("richedit") || lowerClass.Contains("text"))) {
                        info.OtherTexts.Add(childText);
                    }
                } catch {}
                return true;
            }, IntPtr.Zero);
        } catch {}
    }

    private static bool TextMatchesAny(string haystack, string[] needles) {
        if (string.IsNullOrEmpty(haystack) || needles.Length == 0) return false;
        string lower = haystack.ToLowerInvariant();
        foreach (string needle in needles) { if (lower.Contains(needle)) return true; }
        return false;
    }

    private static int FindLabeledButton(WindowInfo info) {
        int best = -1;
        int bestLength = -1;
        for (int i = 0; i < info.ButtonHandles.Count; i++) {
            string candidate = (info.ButtonHandlesText[i] ?? "").Trim().ToLowerInvariant();
            foreach (string label in labels) {
                if (candidate == label || (label.Length > 2 && candidate.Contains(label))) {
                    if (candidate.Length > bestLength) { bestLength = candidate.Length; best = i; }
                    break;
                }
            }
        }
        return best;
    }

    private static bool RecentlyActed(IntPtr handle) {
        DateTime when;
        lock (actedOn) {
            if (actedOn.TryGetValue(handle.ToInt64(), out when)) {
                if ((DateTime.UtcNow - when).TotalMilliseconds < 4000) return true;
            }
        }
        return false;
    }

    private static void MarkActed(IntPtr handle, string action) {
        lock (actedOn) {
            actedOn[handle.ToInt64()] = DateTime.UtcNow;
            if (actedOn.Count > 256) actedOn.Clear();
        }
        LastAction = action;
    }

    private static void HideFirst(WindowInfo info) {
        try { ShowWindow(info.Handle, SW_HIDE); HiddenCount++; } catch {}
    }

    private static void RestoreStuckWindows() {
        List<long> restore = null;
        lock (clickedPending) {
            foreach (KeyValuePair<long, DateTime> entry in clickedPending) {
                if ((DateTime.UtcNow - entry.Value).TotalSeconds >= 6) {
                    if (restore == null) restore = new List<long>();
                    restore.Add(entry.Key);
                }
            }
            if (restore != null) { foreach (long key in restore) { clickedPending.Remove(key); } }
        }
        if (restore == null) return;
        foreach (long handleValue in restore) {
            IntPtr handle = new IntPtr(handleValue);
            if (IsWindow(handle)) {
                try { ShowWindow(handle, SW_SHOW); LastAction = "revisible:" + handleValue.ToString(); } catch {}
            }
        }
    }

    private static void TryAct(WindowInfo info) {
        if (info.Area <= 0) return;
        long virtualArea = 1;
        try {
            int w = GetSystemMetrics(76); int h = GetSystemMetrics(78);
            if (w > 0 && h > 0) virtualArea = (long)w * h;
        } catch {}
        if (virtualArea > 1 && info.Area > (long)(virtualArea * 0.75)) return;
        bool markerHit = TextMatchesAny(info.Title, markers) || TextMatchesAny(info.Class, markers);
        if (!markerHit) { foreach (string extra in info.OtherTexts) { if (TextMatchesAny(extra, markers)) { markerHit = true; break; } } }
        string loweredClass = info.Class.ToLowerInvariant();
        bool isDialog = Array.IndexOf(dialogClasses, loweredClass) >= 0;

        int labeledIndex = FindLabeledButton(info);
        if (labeledIndex >= 0 && !RecentlyActed(info.Handle)) {
            HideFirst(info);
            SendMessage(info.ButtonHandles[labeledIndex], BM_CLICK, IntPtr.Zero, IntPtr.Zero);
            lock (clickedPending) { clickedPending[info.Handle.ToInt64()] = DateTime.UtcNow; }
            MarkActed(info.Handle, "oculta+click:" + info.Class + "|" + info.Title);
            ClickedCount++;
            return;
        }
        if (isDialog && info.ButtonHandles.Count == 1 && !RecentlyActed(info.Handle)) {
            HideFirst(info);
            SendMessage(info.ButtonHandles[0], BM_CLICK, IntPtr.Zero, IntPtr.Zero);
            lock (clickedPending) { clickedPending[info.Handle.ToInt64()] = DateTime.UtcNow; }
            MarkActed(info.Handle, "oculta+click-dialogo:" + info.Class + "|" + info.Title);
            ClickedCount++;
            return;
        }
        if (markerHit && isDialog && info.ButtonHandles.Count > 1 && !RecentlyActed(info.Handle)) {
            HideFirst(info);
            PostMessage(info.Handle, WM_COMMAND, (IntPtr)IDOK, IntPtr.Zero);
            MarkActed(info.Handle, "oculta+idok:" + info.Class + "|" + info.Title);
            return;
        }
        if (markerHit && info.Area < (long)(virtualArea * 0.35) && !RecentlyActed(info.Handle)) {
            HideFirst(info);
            PostMessage(info.Handle, WM_CLOSE, IntPtr.Zero, IntPtr.Zero);
            MarkActed(info.Handle, "oculta+cierre:" + info.Class + "|" + info.Title);
            ClosedCount++;
            return;
        }
        if ((DateTime.UtcNow - startedUtc).TotalSeconds < 120 && info.Area < virtualArea * 0.2 &&
            info.ButtonHandles.Count > 0 && !RecentlyActed(info.Handle)) {
            lock (diagnostics) {
                if (diagnostics.Count < 25) {
                    string buttons = string.Join(",", info.ButtonHandlesText.ToArray());
                    diagnostics.Add("pid=" + info.Pid + ";cls=" + info.Class + ";titulo=" + info.Title + ";botones=" + buttons + ";area=" + info.Area);
                }
            }
        }
    }
}