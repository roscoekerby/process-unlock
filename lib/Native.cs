using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace ProcessUnlock {

public static class RmLocker {
    [StructLayout(LayoutKind.Sequential)]
    struct RM_UNIQUE_PROCESS { public int dwProcessId; public System.Runtime.InteropServices.ComTypes.FILETIME ProcessStartTime; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct RM_PROCESS_INFO {
        public RM_UNIQUE_PROCESS Process;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string strAppName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string strServiceShortName;
        public int ApplicationType; public uint AppStatus; public uint TSSessionId;
        [MarshalAs(UnmanagedType.Bool)] public bool bRestartable;
    }

    const int ERROR_MORE_DATA = 234;

    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
    static extern int RmStartSession(out uint h, int flags, string key);
    [DllImport("rstrtmgr.dll")]
    static extern int RmEndSession(uint h);
    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
    static extern int RmRegisterResources(uint h, uint nFiles, string[] files, uint nApps, IntPtr apps, uint nSvcs, string[] svcs);
    [DllImport("rstrtmgr.dll")]
    static extern int RmGetList(uint h, out uint needed, ref uint count, [In, Out] RM_PROCESS_INFO[] info, ref uint reasons);

    public static int[] Find(string[] files) {
        uint h; var ids = new List<int>();
        int rc = RmStartSession(out h, 0, Guid.NewGuid().ToString());
        if (rc != 0) throw new Exception("RmStartSession failed: " + rc);
        try {
            rc = RmRegisterResources(h, (uint)files.Length, files, 0, IntPtr.Zero, 0, null);
            if (rc != 0) throw new Exception("RmRegisterResources failed: " + rc);
            uint needed = 0, count = 0, reasons = 0;
            RM_PROCESS_INFO[] info = null;
            // The list can grow between calls, so retry until the buffer is big enough.
            for (int attempt = 0; attempt < 5; attempt++) {
                count = info == null ? 0 : (uint)info.Length;
                rc = RmGetList(h, out needed, ref count, info, ref reasons);
                if (rc != ERROR_MORE_DATA) break;
                info = new RM_PROCESS_INFO[needed + 4];
            }
            if (rc != 0) throw new Exception("RmGetList failed: " + rc);
            for (int i = 0; i < count && info != null; i++) ids.Add(info[i].Process.dwProcessId);
        } finally { RmEndSession(h); }
        return ids.ToArray();
    }
}

public static class HandleScan {
    [StructLayout(LayoutKind.Sequential)]
    struct ENTRY { public IntPtr Object; public UIntPtr Pid; public UIntPtr Handle; public uint Access; public ushort Bt; public ushort TypeIndex; public uint Attr; public uint Res; }

    const int SystemExtendedHandleInformation = 64;
    const int STATUS_INFO_LENGTH_MISMATCH = unchecked((int)0xC0000004);
    const uint PROCESS_DUP_HANDLE = 0x40;
    const uint DUPLICATE_SAME_ACCESS = 2;
    const uint FILE_TYPE_DISK = 1;

    [DllImport("ntdll.dll")] static extern int NtQuerySystemInformation(int cls, IntPtr buf, int len, out int ret);
    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool DuplicateHandle(IntPtr srcProc, IntPtr src, IntPtr dstProc, out IntPtr dst, uint access, bool inherit, uint opts);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll")] static extern uint GetFileType(IntPtr h);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern uint GetFinalPathNameByHandle(IntPtr h, StringBuilder sb, uint len, uint flags);

    static ENTRY[] Snapshot() {
        int len = 1 << 20;
        while (true) {
            IntPtr buf = Marshal.AllocHGlobal(len);
            try {
                int ret; int st = NtQuerySystemInformation(SystemExtendedHandleInformation, buf, len, out ret);
                if (st == STATUS_INFO_LENGTH_MISMATCH) { len = Math.Max(len * 2, ret + 65536); continue; }
                if (st != 0) throw new Exception("NtQuerySystemInformation failed: 0x" + st.ToString("X"));
                long count = Marshal.ReadIntPtr(buf).ToInt64();
                int size = Marshal.SizeOf(typeof(ENTRY));
                IntPtr p = buf + IntPtr.Size * 2;
                var arr = new ENTRY[count];
                for (long i = 0; i < count; i++) arr[i] = (ENTRY)Marshal.PtrToStructure(p + (int)(i * size), typeof(ENTRY));
                return arr;
            } finally { Marshal.FreeHGlobal(buf); }
        }
    }

    static string NormalizePath(string path) {
        if (path.StartsWith(@"\\?\UNC\")) return @"\\" + path.Substring(8);
        if (path.StartsWith(@"\\?\")) return path.Substring(4);
        return path;
    }

    // Access masks typical of synchronous pipes/consoles, whose queries can block forever.
    static readonly HashSet<uint> HangProneAccess = new HashSet<uint> { 0x0012019F, 0x001A019F, 0x00120189, 0x00100000 };
    const int StallMs = 300;
    const int PathBuffer = 1024;

    static string QueryPath(IntPtr h) {
        if (GetFileType(h) != FILE_TYPE_DISK) return null;
        var sb = new StringBuilder(PathBuffer);
        uint n = GetFinalPathNameByHandle(h, sb, (uint)sb.Capacity, 0);
        if (n == 0) return null;
        if (n >= sb.Capacity) {
            sb = new StringBuilder((int)n + 1);
            n = GetFinalPathNameByHandle(h, sb, (uint)sb.Capacity, 0);
            if (n == 0 || n >= sb.Capacity) return null;
        }
        return NormalizePath(sb.ToString());
    }

    sealed class Worker {
        public ENTRY[] Entries; public int FileType, Me; public string Exact, Prefix;
        public volatile int Index; public long StartedTicks; public volatile bool Abandoned;
        public readonly HashSet<int> Ids = new HashSet<int>();
        public readonly Dictionary<int, IntPtr> Procs;
        public Worker(Dictionary<int, IntPtr> procs) { Procs = procs; }

        public void Run() {
            for (; Index < Entries.Length && !Abandoned; Index++) {
                var e = Entries[Index];
                int pid = (int)e.Pid.ToUInt64();
                if (e.TypeIndex != FileType || pid == Me || pid <= 4 || HangProneAccess.Contains(e.Access)) continue;
                lock (Ids) { if (Ids.Contains(pid)) continue; }
                IntPtr ph;
                lock (Procs) { if (!Procs.TryGetValue(pid, out ph)) { ph = OpenProcess(PROCESS_DUP_HANDLE, false, pid); Procs[pid] = ph; } }
                if (ph == IntPtr.Zero) continue;
                IntPtr dup;
                if (!DuplicateHandle(ph, (IntPtr)(long)e.Handle.ToUInt64(), GetCurrentProcess(), out dup, 0, false, DUPLICATE_SAME_ACCESS)) continue;
                Interlocked.Exchange(ref StartedTicks, DateTime.UtcNow.Ticks);
                try {
                    string path = QueryPath(dup);
                    if (path != null && (path.Equals(Exact, StringComparison.OrdinalIgnoreCase) || path.StartsWith(Prefix, StringComparison.OrdinalIgnoreCase)))
                        lock (Ids) Ids.Add(pid);
                } finally { Interlocked.Exchange(ref StartedTicks, 0); CloseHandle(dup); }
            }
        }
    }

    public static int[] Find(string target, string probeFile) {
        int me = System.Diagnostics.Process.GetCurrentProcess().Id;
        var procs = new Dictionary<int, IntPtr>();
        var all = new HashSet<int>();
        string exact = target.TrimEnd('\\');
        try {
            ENTRY[] entries; int fileType = -1;
            using (var probe = System.IO.File.OpenRead(probeFile)) {
                long probeHandle = probe.SafeFileHandle.DangerousGetHandle().ToInt64();
                entries = Snapshot();
                foreach (var e in entries)
                    if ((int)e.Pid.ToUInt64() == me && (long)e.Handle.ToUInt64() == probeHandle) { fileType = e.TypeIndex; break; }
            }
            if (fileType < 0) throw new Exception("Could not resolve File handle type");
            int start = 0;
            // Queries run on a background thread; if one stalls, abandon that thread and resume after the stuck handle.
            while (start < entries.Length) {
                var w = new Worker(procs) { Entries = entries, FileType = fileType, Me = me, Exact = exact, Prefix = exact + "\\", Index = start };
                var t = new Thread(w.Run) { IsBackground = true };
                t.Start();
                while (!t.Join(50)) {
                    long s = Interlocked.Read(ref w.StartedTicks);
                    if (s != 0 && (DateTime.UtcNow.Ticks - s) / TimeSpan.TicksPerMillisecond > StallMs) break;
                }
                if (t.IsAlive) w.Abandoned = true;
                lock (w.Ids) all.UnionWith(w.Ids);
                if (!t.IsAlive) break;
                start = w.Index + 1;
            }
        } finally {
            lock (procs) foreach (var h in procs.Values) if (h != IntPtr.Zero) CloseHandle(h);
        }
        var result = new int[all.Count]; all.CopyTo(result); return result;
    }
}

public static class Win {
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }


    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder sb, int n);

    public static long[] FindByClass(string className) {
        var found = new List<long>();
        var sb = new StringBuilder(256);
        EnumWindows((h, l) => {
            if (!IsWindowVisible(h)) return true;
            sb.Clear();
            GetClassName(h, sb, 256);
            if (sb.ToString() == className) found.Add(h.ToInt64());
            return true;
        }, IntPtr.Zero);
        return found.ToArray();
    }

    public static bool Exists(long hwnd) { return IsWindow(new IntPtr(hwnd)); }

    public static int[] Rect(long hwnd) {
        RECT r;
        if (!GetWindowRect(new IntPtr(hwnd), out r)) return null;
        return new[] { r.Left, r.Top, r.Right, r.Bottom };
    }
}
}
