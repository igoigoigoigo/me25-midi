// ME-25 MIDI - transforma os switches MEMORY ▼, MEMORY ▲ e SOLO da BOSS ME-25 em mensagens MIDI.
// A ME-25 nao envia MIDI dos footswitches; o app le o patch atual por SysEx (Roland RQ1, endereco 7F 7F 00 00)
// varias vezes por segundo e converte as mudancas em CC / Program Change.
// Compilar: build.cmd (usa o csc do .NET Framework 4, que ja vem no Windows).
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;

namespace ME25Midi
{
    // ------------------------------------------------------------------ WinMM
    static class WinMM
    {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
        public struct INCAPS { public ushort wMid, wPid; public uint v;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string name; public uint sup; }
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
        public struct OUTCAPS { public ushort wMid, wPid; public uint v;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string name;
            public ushort t, vo, n, cm; public uint sup; }
        [StructLayout(LayoutKind.Sequential)]
        public struct MIDIHDR { public IntPtr lpData; public uint dwBufferLength, dwBytesRecorded;
            public IntPtr dwUser; public uint dwFlags; public IntPtr lpNext, reserved; public uint dwOffset;
            [MarshalAs(UnmanagedType.ByValArray, SizeConst = 8)] public IntPtr[] dwReserved; }
        public delegate void Proc(IntPtr h, uint msg, IntPtr inst, IntPtr p1, IntPtr p2);

        [DllImport("winmm.dll")] public static extern uint midiInGetNumDevs();
        [DllImport("winmm.dll")] public static extern uint midiOutGetNumDevs();
        [DllImport("winmm.dll", CharSet = CharSet.Auto)] public static extern uint midiInGetDevCaps(UIntPtr i, out INCAPS c, uint s);
        [DllImport("winmm.dll", CharSet = CharSet.Auto)] public static extern uint midiOutGetDevCaps(UIntPtr i, out OUTCAPS c, uint s);
        [DllImport("winmm.dll")] public static extern uint midiInOpen(out IntPtr h, uint id, Proc cb, IntPtr inst, uint f);
        [DllImport("winmm.dll")] public static extern uint midiOutOpen(out IntPtr h, uint id, IntPtr cb, IntPtr inst, uint f);
        [DllImport("winmm.dll")] public static extern uint midiInPrepareHeader(IntPtr h, IntPtr hdr, uint s);
        [DllImport("winmm.dll")] public static extern uint midiInUnprepareHeader(IntPtr h, IntPtr hdr, uint s);
        [DllImport("winmm.dll")] public static extern uint midiInAddBuffer(IntPtr h, IntPtr hdr, uint s);
        [DllImport("winmm.dll")] public static extern uint midiInStart(IntPtr h);
        [DllImport("winmm.dll")] public static extern uint midiInStop(IntPtr h);
        [DllImport("winmm.dll")] public static extern uint midiInReset(IntPtr h);
        [DllImport("winmm.dll")] public static extern uint midiInClose(IntPtr h);
        [DllImport("winmm.dll")] public static extern uint midiOutPrepareHeader(IntPtr h, IntPtr hdr, uint s);
        [DllImport("winmm.dll")] public static extern uint midiOutUnprepareHeader(IntPtr h, IntPtr hdr, uint s);
        [DllImport("winmm.dll")] public static extern uint midiOutLongMsg(IntPtr h, IntPtr hdr, uint s);
        [DllImport("winmm.dll")] public static extern uint midiOutShortMsg(IntPtr h, uint msg);
        [DllImport("winmm.dll")] public static extern uint midiOutReset(IntPtr h);
        [DllImport("winmm.dll")] public static extern uint midiOutClose(IntPtr h);

        public static string InName(uint i) { INCAPS c; return midiInGetDevCaps((UIntPtr)i, out c, (uint)Marshal.SizeOf(typeof(INCAPS))) == 0 ? c.name : ""; }
        public static string OutName(uint i) { OUTCAPS c; return midiOutGetDevCaps((UIntPtr)i, out c, (uint)Marshal.SizeOf(typeof(OUTCAPS))) == 0 ? c.name : ""; }
        public static int FindIn(string part) { for (uint i = 0; i < midiInGetNumDevs(); i++) if (InName(i).IndexOf(part, StringComparison.OrdinalIgnoreCase) >= 0) return (int)i; return -1; }
        public static int FindOut(string part) { for (uint i = 0; i < midiOutGetNumDevs(); i++) if (OutName(i).IndexOf(part, StringComparison.OrdinalIgnoreCase) >= 0) return (int)i; return -1; }
        public static uint HS { get { return (uint)Marshal.SizeOf(typeof(MIDIHDR)); } }
    }

    // ------------------------------------------------------------------ conexao SysEx com a ME-25
    class Me25Link : IDisposable
    {
        IntPtr hin = IntPtr.Zero, hout = IntPtr.Zero;
        readonly IntPtr[] hdrs = new IntPtr[8];
        volatile bool running;
        readonly WinMM.Proc cb;
        public readonly ConcurrentQueue<byte[]> Rx = new ConcurrentQueue<byte[]>();

        public Me25Link() { cb = OnMsg; }

        void OnMsg(IntPtr h, uint msg, IntPtr inst, IntPtr p1, IntPtr p2)
        {
            if (msg != 0x3C4) return; // MIM_LONGDATA
            WinMM.MIDIHDR hd = (WinMM.MIDIHDR)Marshal.PtrToStructure(p1, typeof(WinMM.MIDIHDR));
            if (hd.dwBytesRecorded > 0) { byte[] b = new byte[hd.dwBytesRecorded]; Marshal.Copy(hd.lpData, b, 0, b.Length); Rx.Enqueue(b); }
            if (running) WinMM.midiInAddBuffer(hin, p1, WinMM.HS);
        }

        public string Open()
        {
            int iin = WinMM.FindIn("ME-25"), iout = WinMM.FindOut("ME-25");
            if (iin < 0 || iout < 0) return "ME-25 nao encontrada (ligada no USB? driver instalado?)";
            if (WinMM.midiInOpen(out hin, (uint)iin, cb, IntPtr.Zero, 0x30000) != 0) { hin = IntPtr.Zero; return "Porta da ME-25 em uso (feche o BOSS TONE STUDIO)"; }
            if (WinMM.midiOutOpen(out hout, (uint)iout, IntPtr.Zero, IntPtr.Zero, 0) != 0) { hout = IntPtr.Zero; Dispose(); return "Porta de saida da ME-25 em uso"; }
            for (int k = 0; k < hdrs.Length; k++)
            {
                WinMM.MIDIHDR hd = new WinMM.MIDIHDR();
                hd.lpData = Marshal.AllocHGlobal(4096); hd.dwBufferLength = 4096; hd.dwReserved = new IntPtr[8];
                hdrs[k] = Marshal.AllocHGlobal((int)WinMM.HS); Marshal.StructureToPtr(hd, hdrs[k], false);
                WinMM.midiInPrepareHeader(hin, hdrs[k], WinMM.HS); WinMM.midiInAddBuffer(hin, hdrs[k], WinMM.HS);
            }
            running = true; WinMM.midiInStart(hin);
            return null;
        }

        public void SendSysex(byte[] data)
        {
            if (hout == IntPtr.Zero) return;
            IntPtr buf = Marshal.AllocHGlobal(data.Length); Marshal.Copy(data, 0, buf, data.Length);
            WinMM.MIDIHDR hd = new WinMM.MIDIHDR(); hd.lpData = buf; hd.dwBufferLength = (uint)data.Length; hd.dwBytesRecorded = (uint)data.Length; hd.dwReserved = new IntPtr[8];
            IntPtr p = Marshal.AllocHGlobal((int)WinMM.HS); Marshal.StructureToPtr(hd, p, false);
            WinMM.midiOutPrepareHeader(hout, p, WinMM.HS); WinMM.midiOutLongMsg(hout, p, WinMM.HS);
            for (int i = 0; i < 300; i++) { WinMM.MIDIHDR c = (WinMM.MIDIHDR)Marshal.PtrToStructure(p, typeof(WinMM.MIDIHDR)); if ((c.dwFlags & 1) != 0) break; Thread.Sleep(1); }
            WinMM.midiOutUnprepareHeader(hout, p, WinMM.HS); Marshal.FreeHGlobal(p); Marshal.FreeHGlobal(buf);
        }

        // Roland RQ1: F0 41 10 00 00 45 11 aa aa aa aa ss ss ss ss sum F7
        public static byte[] Rq1(byte a0, byte a1, byte a2, byte a3)
        {
            byte[] b = { a0, a1, a2, a3, 0, 0, 0, 0x10 }; int s = 0; foreach (byte x in b) s += x;
            List<byte> m = new List<byte> { 0xF0, 0x41, 0x10, 0x00, 0x00, 0x45, 0x11 }; m.AddRange(b);
            m.Add((byte)((128 - (s % 128)) % 128)); m.Add(0xF7); return m.ToArray();
        }

        // Faz um pedido e espera a resposta (DT1) do mesmo endereco.
        public byte[] Request(byte a0, byte a1, byte a2, byte a3, int timeoutMs)
        {
            byte[] tmp; while (Rx.TryDequeue(out tmp)) { }
            SendSysex(Rq1(a0, a1, a2, a3));
            DateTime end = DateTime.Now.AddMilliseconds(timeoutMs);
            while (DateTime.Now < end)
            {
                byte[] m;
                while (Rx.TryDequeue(out m))
                    if (m.Length >= 141 && m[1] == 0x41 && m[6] == 0x12 && m[7] == a0 && m[8] == a1 && m[9] == a2 && m[10] == a3) return m;
                Thread.Sleep(2);
            }
            return null;
        }

        public static string PatchName(byte[] m) { char[] c = new char[16]; for (int i = 0; i < 16; i++) c[i] = (char)m[11 + 97 + 2 * i]; return new string(c).Trim(); }
        public static bool SoloOn(byte[] m) { return m[11 + 85] != 0; }

        public void Dispose()
        {
            running = false;
            if (hin != IntPtr.Zero)
            {
                WinMM.midiInStop(hin); WinMM.midiInReset(hin);
                for (int k = 0; k < hdrs.Length; k++) if (hdrs[k] != IntPtr.Zero) { WinMM.midiInUnprepareHeader(hin, hdrs[k], WinMM.HS); hdrs[k] = IntPtr.Zero; }
                WinMM.midiInClose(hin); hin = IntPtr.Zero;
            }
            if (hout != IntPtr.Zero) { WinMM.midiOutClose(hout); hout = IntPtr.Zero; }
        }
    }

    // ------------------------------------------------------------------ saida MIDI
    interface IMidiSink : IDisposable { string Name { get; } void Send(byte[] msg); }

    class WinMMSink : IMidiSink
    {
        IntPtr h; readonly string name;
        public WinMMSink(int id) { name = WinMM.OutName((uint)id); if (WinMM.midiOutOpen(out h, (uint)id, IntPtr.Zero, IntPtr.Zero, 0) != 0) throw new Exception("Nao foi possivel abrir '" + name + "' (em uso?)"); }
        public string Name { get { return name; } }
        public void Send(byte[] m) { uint v = 0; for (int i = 0; i < m.Length && i < 3; i++) v |= (uint)m[i] << (8 * i); WinMM.midiOutShortMsg(h, v); }
        public void Dispose() { if (h != IntPtr.Zero) { WinMM.midiOutReset(h); WinMM.midiOutClose(h); h = IntPtr.Zero; } }
    }

    // Porta virtual propria via driver do loopMIDI (teVirtualMIDI, Tobias Erichsen).
    class VirtualSink : IMidiSink
    {
        public delegate void DataCB(IntPtr port, IntPtr data, uint len, IntPtr inst);
        [DllImport("teVirtualMIDI64.dll", EntryPoint = "virtualMIDICreatePortEx2", SetLastError = true, CharSet = CharSet.Unicode)]
        static extern IntPtr CreatePortEx2(string name, DataCB cb, IntPtr inst, uint maxSysex, uint flags);
        [DllImport("teVirtualMIDI64.dll", EntryPoint = "virtualMIDIClosePort")] static extern void ClosePort(IntPtr port);
        [DllImport("teVirtualMIDI64.dll", EntryPoint = "virtualMIDISendData", SetLastError = true)] static extern bool SendData(IntPtr port, byte[] data, uint len);

        const uint PARSE_RX = 1, INSTANTIATE_TX_ONLY = 8;
        IntPtr port; readonly string name; readonly DataCB keep;
        public VirtualSink(string portName)
        {
            name = portName; keep = (p, d, l, i) => { };
            port = CreatePortEx2(portName, keep, IntPtr.Zero, 65535, PARSE_RX | INSTANTIATE_TX_ONLY);
            if (port == IntPtr.Zero) throw new Exception("Nao foi possivel criar a porta virtual (erro " + Marshal.GetLastWin32Error() + ")");
        }
        public static bool Available
        {
            get { return File.Exists(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "teVirtualMIDI64.dll")) || File.Exists(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "teVirtualMIDI64.dll")); }
        }
        public string Name { get { return name + " (virtual)"; } }
        public void Send(byte[] m) { if (port != IntPtr.Zero) SendData(port, m, (uint)m.Length); }
        public void Dispose() { if (port != IntPtr.Zero) { ClosePort(port); port = IntPtr.Zero; } }
    }

    // ------------------------------------------------------------------ configuracoes
    class Settings
    {
        public string Output = "*virtual*";
        public int Channel = 1, CcDown = 20, CcUp = 21, CcSolo = 22;
        public bool ProgramChange = false, StartMinimized = false;
        static string FilePath { get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "ME25MIDI", "settings.ini"); } }

        public static Settings Load()
        {
            Settings s = new Settings();
            try
            {
                if (!File.Exists(FilePath)) return s;
                foreach (string line in File.ReadAllLines(FilePath))
                {
                    int i = line.IndexOf('='); if (i < 0) continue;
                    string k = line.Substring(0, i).Trim(), v = line.Substring(i + 1).Trim(); int n;
                    if (k == "Output") s.Output = v;
                    else if (k == "Channel" && int.TryParse(v, out n)) s.Channel = n;
                    else if (k == "CcDown" && int.TryParse(v, out n)) s.CcDown = n;
                    else if (k == "CcUp" && int.TryParse(v, out n)) s.CcUp = n;
                    else if (k == "CcSolo" && int.TryParse(v, out n)) s.CcSolo = n;
                    else if (k == "ProgramChange") s.ProgramChange = v == "1";
                    else if (k == "StartMinimized") s.StartMinimized = v == "1";
                }
            }
            catch { }
            return s;
        }
        public void Save()
        {
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(FilePath));
                File.WriteAllLines(FilePath, new[] {
                    "Output=" + Output, "Channel=" + Channel, "CcDown=" + CcDown, "CcUp=" + CcUp, "CcSolo=" + CcSolo,
                    "ProgramChange=" + (ProgramChange ? "1" : "0"), "StartMinimized=" + (StartMinimized ? "1" : "0") });
            }
            catch { }
        }
    }

    // ------------------------------------------------------------------ motor (thread de polling)
    enum Ev { Status, Patch, Down, Up, Solo, Log }

    class Engine
    {
        const int N = 60;
        public volatile bool Stop;
        public Action<Ev, string, int> Notify = delegate { };
        public Func<Settings> GetSettings;
        public Action<byte[]> Out = delegate { };

        public void Run()
        {
            while (!Stop)
            {
                using (Me25Link link = new Me25Link())
                {
                    string err = link.Open();
                    if (err != null) { Notify(Ev.Status, err, 0); Sleep(2000); continue; }
                    Notify(Ev.Status, "Conectando... lendo os 60 patches", 0);

                    string[] names = new string[N]; int ok = 0;
                    for (int p = 0; p < N && !Stop; p++)
                    {
                        byte[] m = link.Request(0x7F, 0x00, (byte)p, 0x00, 400);
                        if (m != null) { names[p] = Me25Link.PatchName(m); ok++; }
                    }
                    if (ok == 0) { Notify(Ev.Status, "A ME-25 nao respondeu. Tentando de novo...", 0); Sleep(2000); continue; }
                    Notify(Ev.Log, "Patches carregados: " + ok + "/" + N, 0);

                    string curName = null; int curIdx = -1; bool solo = false; int misses = 0;
                    while (!Stop)
                    {
                        byte[] m = link.Request(0x7F, 0x7F, 0x00, 0x00, 400);
                        if (m == null)
                        {
                            if (++misses >= 5) { Notify(Ev.Status, "ME-25 parou de responder. Reconectando...", 0); break; }
                            continue;
                        }
                        misses = 0;
                        Settings s = GetSettings(); int ch = Math.Max(1, Math.Min(16, s.Channel)) - 1;
                        string name = Me25Link.PatchName(m); bool so = Me25Link.SoloOn(m);

                        if (curName == null)
                        {
                            curName = name; curIdx = FindIdx(names, name, -1); solo = so;
                            Notify(Ev.Status, "Conectada", 0);
                            Notify(Ev.Patch, name, curIdx);
                            Notify(Ev.Solo, so ? "1" : "0", -1);
                        }
                        else if (name != curName)
                        {
                            int idx = FindIdx(names, name, curIdx); int dir = 0;
                            if (idx >= 0 && curIdx >= 0) { int d = (idx - curIdx + N) % N; if (d != 0) dir = d <= N / 2 ? 1 : -1; }
                            if (dir != 0)
                            {
                                int cc = dir > 0 ? s.CcUp : s.CcDown;
                                Out(new byte[] { (byte)(0xB0 + ch), (byte)cc, 127 });
                                Out(new byte[] { (byte)(0xB0 + ch), (byte)cc, 0 });
                                Notify(dir > 0 ? Ev.Up : Ev.Down, "CC" + cc, idx);
                            }
                            if (s.ProgramChange && idx >= 0) Out(new byte[] { (byte)(0xC0 + ch), (byte)idx });
                            Notify(Ev.Patch, name, idx);
                            curName = name; curIdx = idx;
                            if (so != solo) { solo = so; Notify(Ev.Solo, so ? "1" : "0", -1); } // estado do SOLO do novo patch, sem CC
                        }
                        else if (so != solo)
                        {
                            solo = so;
                            Out(new byte[] { (byte)(0xB0 + ch), (byte)s.CcSolo, (byte)(so ? 127 : 0) });
                            Notify(Ev.Solo, so ? "1" : "0", s.CcSolo);
                        }
                        Sleep(40);
                    }
                }
            }
        }

        void Sleep(int ms) { for (int i = 0; i < ms / 50 && !Stop; i++) Thread.Sleep(50); }

        static int FindIdx(string[] names, string name, int near)
        {
            int best = -1, bestD = int.MaxValue;
            for (int i = 0; i < names.Length; i++)
            {
                if (names[i] != name) continue;
                if (near < 0) return i;
                int d = Math.Abs(i - near); d = Math.Min(d, names.Length - d);
                if (d < bestD) { bestD = d; best = i; }
            }
            return best;
        }
    }

    // ------------------------------------------------------------------ interface
    class MainForm : Form
    {
        readonly Settings settings = Settings.Load();
        readonly object outLock = new object();
        IMidiSink sink;
        Engine engine; Thread worker;

        Label lblStatus, lblOut;
        Panel ledDown, ledUp, ledSolo;
        ComboBox cmbOut; NumericUpDown numCh, numDown, numUp, numSolo;
        CheckBox chkPC, chkMin; ListBox log;
        NotifyIcon tray;
        System.Windows.Forms.Timer flashTimer;
        DateTime downUntil, upUntil;
        bool soloOn, loading = true;

        static readonly Color Off = Color.FromArgb(55, 55, 60), Green = Color.FromArgb(60, 200, 90), Red = Color.FromArgb(230, 60, 50), Bg = Color.FromArgb(28, 28, 32), Fg = Color.Gainsboro;

        public MainForm()
        {
            Text = "ME-25 MIDI"; FormBorderStyle = FormBorderStyle.FixedSingle; MaximizeBox = false;
            ClientSize = new Size(460, 440); BackColor = Bg; ForeColor = Fg; Font = new Font("Segoe UI", 9f);
            Icon appIcon = SystemIcons.Application;
            try { appIcon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { }
            Icon = appIcon;

            lblStatus = new Label { Left = 16, Top = 12, Width = 430, Height = 20, ForeColor = Color.Orange, Text = "Iniciando..." };
            Controls.Add(lblStatus);

            ledDown = Led("MEMORY ▼", 16); ledUp = Led("MEMORY ▲", 166); ledSolo = Led("SOLO", 316);

            GroupBox g = new GroupBox { Left = 16, Top = 112, Width = 428, Height = 170, Text = "Saída MIDI", ForeColor = Fg };
            Controls.Add(g);
            g.Controls.Add(new Label { Left = 12, Top = 26, Width = 60, Text = "Porta:" });
            cmbOut = new ComboBox { Left = 80, Top = 22, Width = 260, DropDownStyle = ComboBoxStyle.DropDownList };
            Button btnRef = new Button { Left = 346, Top = 21, Width = 70, Height = 25, Text = "Atualizar", ForeColor = Color.Black, BackColor = SystemColors.Control };
            btnRef.Click += (o, e) => FillPorts();
            lblOut = new Label { Left = 80, Top = 50, Width = 336, Height = 18, ForeColor = Color.Gray };
            g.Controls.AddRange(new Control[] { cmbOut, btnRef, lblOut });

            numCh = Num(g, "Canal", 12, 78, 1, 16, settings.Channel);
            numDown = Num(g, "CC ▼", 150, 78, 0, 127, settings.CcDown);
            numUp = Num(g, "CC ▲", 290, 78, 0, 127, settings.CcUp);
            numSolo = Num(g, "CC SOLO", 12, 108, 0, 127, settings.CcSolo);
            chkPC = new CheckBox { Left = 150, Top = 108, Width = 260, Text = "Enviar também Program Change", Checked = settings.ProgramChange };
            chkMin = new CheckBox { Left = 150, Top = 136, Width = 260, Text = "Iniciar minimizado na bandeja", Checked = settings.StartMinimized };
            g.Controls.AddRange(new Control[] { chkPC, chkMin });
            EventHandler save = (o, e) => SaveSettings();
            numCh.ValueChanged += save; numDown.ValueChanged += save; numUp.ValueChanged += save; numSolo.ValueChanged += save;
            chkPC.CheckedChanged += save; chkMin.CheckedChanged += save;
            cmbOut.SelectedIndexChanged += (o, e) => { if (!loading) { SaveSettings(); OpenOutput(); } };

            log = new ListBox { Left = 16, Top = 294, Width = 428, Height = 134, BackColor = Color.FromArgb(20, 20, 24), ForeColor = Color.Silver, BorderStyle = BorderStyle.FixedSingle, IntegralHeight = false };
            Controls.Add(log);

            tray = new NotifyIcon { Icon = appIcon, Text = "ME-25 MIDI", Visible = true };
            tray.DoubleClick += (o, e) => RestoreFromTray();
            tray.ContextMenu = new ContextMenu(new[] { new MenuItem("Abrir", (o, e) => RestoreFromTray()), new MenuItem("Sair", (o, e) => Close()) });
            Resize += (o, e) => { if (WindowState == FormWindowState.Minimized) Hide(); };

            flashTimer = new System.Windows.Forms.Timer { Interval = 30 };
            flashTimer.Tick += (o, e) => { ledDown.BackColor = DateTime.Now < downUntil ? Green : Off; ledUp.BackColor = DateTime.Now < upUntil ? Green : Off; ledSolo.BackColor = soloOn ? Red : Off; };
            flashTimer.Start();

            FillPorts(); loading = false; OpenOutput();

            engine = new Engine();
            engine.GetSettings = () => settings;
            engine.Out = m => { lock (outLock) { if (sink != null) sink.Send(m); } };
            engine.Notify = (ev, s, n) => { try { BeginInvoke(new Action(() => OnEvent(ev, s, n))); } catch { } };
            worker = new Thread(engine.Run) { IsBackground = true, Name = "ME-25 poll" };
            worker.Start();

            if (settings.StartMinimized) { Load += (o, e) => { WindowState = FormWindowState.Minimized; Hide(); }; }
        }

        Panel Led(string text, int left)
        {
            Panel p = new Panel { Left = left, Top = 38, Width = 128, Height = 64, BackColor = Off };
            p.Controls.Add(new Label { Dock = DockStyle.Fill, Text = text, TextAlign = ContentAlignment.MiddleCenter, Font = new Font("Segoe UI", 11f, FontStyle.Bold), ForeColor = Color.White, BackColor = Color.Transparent });
            Controls.Add(p); return p;
        }

        NumericUpDown Num(Control parent, string label, int left, int top, int min, int max, int val)
        {
            parent.Controls.Add(new Label { Left = left, Top = top + 3, Width = 62, Text = label });
            NumericUpDown n = new NumericUpDown { Left = left + 66, Top = top, Width = 56, Minimum = min, Maximum = max, Value = Math.Max(min, Math.Min(max, val)) };
            parent.Controls.Add(n); return n;
        }

        class PortItem { public string Key, Text; public override string ToString() { return Text; } }

        void FillPorts()
        {
            bool was = loading; loading = true;
            cmbOut.Items.Clear();
            cmbOut.Items.Add(new PortItem { Key = "*virtual*", Text = VirtualSink.Available ? "Porta virtual \"ME-25 MIDI\" (loopMIDI)" : "Porta virtual \"ME-25 MIDI\" (instale o loopMIDI)" });
            for (uint i = 0; i < WinMM.midiOutGetNumDevs(); i++)
            {
                string n = WinMM.OutName(i);
                if (n.IndexOf("ME-25", StringComparison.OrdinalIgnoreCase) >= 0) continue;
                cmbOut.Items.Add(new PortItem { Key = n, Text = n });
            }
            cmbOut.Items.Add(new PortItem { Key = "*none*", Text = "(nenhuma - só monitorar)" });
            int sel = 0;
            for (int i = 0; i < cmbOut.Items.Count; i++) if (((PortItem)cmbOut.Items[i]).Key == settings.Output) sel = i;
            cmbOut.SelectedIndex = sel;
            loading = was;
            if (!loading) OpenOutput();
        }

        void OpenOutput()
        {
            PortItem it = cmbOut.SelectedItem as PortItem; if (it == null) return;
            lock (outLock)
            {
                if (sink != null) { sink.Dispose(); sink = null; }
                try
                {
                    if (it.Key == "*virtual*")
                    {
                        if (!VirtualSink.Available) throw new Exception("loopMIDI não instalado - instale-o ou escolha outra porta");
                        sink = new VirtualSink("ME-25 MIDI");
                    }
                    else if (it.Key != "*none*")
                    {
                        int id = WinMM.FindOut(it.Key); if (id < 0) throw new Exception("Porta não encontrada");
                        sink = new WinMMSink(id);
                    }
                    lblOut.ForeColor = Color.Gray; lblOut.Text = sink != null ? "Enviando para: " + sink.Name : "Sem saída - apenas monitorando";
                }
                catch (Exception ex) { sink = null; lblOut.ForeColor = Color.Orange; lblOut.Text = ex.Message; }
            }
            AddLog(lblOut.Text);
        }

        void SaveSettings()
        {
            if (loading) return;
            PortItem it = cmbOut.SelectedItem as PortItem;
            if (it != null) settings.Output = it.Key;
            settings.Channel = (int)numCh.Value; settings.CcDown = (int)numDown.Value; settings.CcUp = (int)numUp.Value; settings.CcSolo = (int)numSolo.Value;
            settings.ProgramChange = chkPC.Checked; settings.StartMinimized = chkMin.Checked;
            settings.Save();
        }

        void OnEvent(Ev ev, string s, int n)
        {
            switch (ev)
            {
                case Ev.Status:
                    lblStatus.Text = s; lblStatus.ForeColor = s == "Conectada" ? Green : Color.Orange;
                    tray.Text = "ME-25 MIDI - " + (s.Length > 40 ? s.Substring(0, 40) : s);
                    AddLog(s); break;
                case Ev.Patch: break;
                case Ev.Down: downUntil = DateTime.Now.AddMilliseconds(250); AddLog("MEMORY ▼  → " + s); break;
                case Ev.Up: upUntil = DateTime.Now.AddMilliseconds(250); AddLog("MEMORY ▲  → " + s); break;
                case Ev.Solo:
                    soloOn = s == "1";
                    if (n >= 0) AddLog("SOLO " + (soloOn ? "ON " : "OFF") + " → CC" + n + " = " + (soloOn ? 127 : 0));
                    break;
                case Ev.Log: AddLog(s); break;
            }
        }

        void AddLog(string s)
        {
            log.Items.Add(DateTime.Now.ToString("HH:mm:ss") + "  " + s);
            while (log.Items.Count > 300) log.Items.RemoveAt(0);
            log.TopIndex = log.Items.Count - 1;
        }

        void RestoreFromTray() { Show(); WindowState = FormWindowState.Normal; Activate(); }

        protected override void OnFormClosing(FormClosingEventArgs e)
        {
            engine.Stop = true; worker.Join(1500);
            lock (outLock) { if (sink != null) { sink.Dispose(); sink = null; } }
            tray.Visible = false; tray.Dispose();
            base.OnFormClosing(e);
        }
    }

    static class Program
    {
        [STAThread]
        static void Main()
        {
            bool created;
            using (Mutex mtx = new Mutex(true, "ME25MIDI_SingleInstance", out created))
            {
                if (!created) { MessageBox.Show("O ME-25 MIDI já está aberto (veja a bandeja do relógio).", "ME-25 MIDI"); return; }
                Application.EnableVisualStyles();
                Application.Run(new MainForm());
            }
        }
    }
}
