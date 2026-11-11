param(
  # Porta MIDI de saida (parte do nome). Ex.: 'loopMIDI', 'ME25 Bridge'. Vazio = so mostra no console.
  [string]$OutPort = 'loopMIDI',
  [int]$Channel   = 1,     # canal MIDI 1-16
  [int]$CcDown    = 20,    # Memory esquerdo (desce patch)  -> CC momentaneo 127 e depois 0
  [int]$CcUp      = 21,    # Memory direito (sobe patch)    -> CC momentaneo 127 e depois 0
  [int]$CcSolo    = 22,    # SOLO                           -> CC 127 (liga) / 0 (desliga)
  [switch]$ProgramChange,  # tambem envia Program Change com o numero do patch (0-59)
  [int]$PollMs    = 60,
  [int]$Seconds   = 0      # 0 = roda ate Ctrl+C
)
# Ponte ME-25 -> MIDI. A ME-25 nao envia MIDI dos footswitches; este script le o patch atual
# por SysEx (endereco 7F 7F 00 00) varias vezes por segundo e converte as mudancas em MIDI.
# Feche o BOSS TONE STUDIO antes de rodar (ele ocupa a porta).

$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @"
using System;
using System.Collections.Concurrent;
using System.Runtime.InteropServices;
public static class Me25 {
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Auto)]
  public struct INCAPS { public ushort wMid, wPid; public uint v;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string name; public uint sup; }
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Auto)]
  public struct OUTCAPS { public ushort wMid, wPid; public uint v;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string name;
    public ushort t, vo, n, cm; public uint sup; }
  [StructLayout(LayoutKind.Sequential)]
  public struct MIDIHDR { public IntPtr lpData; public uint dwBufferLength, dwBytesRecorded;
    public IntPtr dwUser; public uint dwFlags; public IntPtr lpNext, reserved; public uint dwOffset;
    [MarshalAs(UnmanagedType.ByValArray, SizeConst=8)] public IntPtr[] dwReserved; }
  public delegate void Proc(IntPtr h, uint msg, IntPtr inst, IntPtr p1, IntPtr p2);
  [DllImport("winmm.dll")] public static extern uint midiInGetNumDevs();
  [DllImport("winmm.dll")] public static extern uint midiOutGetNumDevs();
  [DllImport("winmm.dll", CharSet=CharSet.Auto)] static extern uint midiInGetDevCaps(UIntPtr i, out INCAPS c, uint s);
  [DllImport("winmm.dll", CharSet=CharSet.Auto)] static extern uint midiOutGetDevCaps(UIntPtr i, out OUTCAPS c, uint s);
  [DllImport("winmm.dll")] static extern uint midiInOpen(out IntPtr h, uint id, Proc cb, IntPtr inst, uint f);
  [DllImport("winmm.dll")] static extern uint midiOutOpen(out IntPtr h, uint id, IntPtr cb, IntPtr inst, uint f);
  [DllImport("winmm.dll")] static extern uint midiInPrepareHeader(IntPtr h, IntPtr hdr, uint s);
  [DllImport("winmm.dll")] static extern uint midiInUnprepareHeader(IntPtr h, IntPtr hdr, uint s);
  [DllImport("winmm.dll")] static extern uint midiInAddBuffer(IntPtr h, IntPtr hdr, uint s);
  [DllImport("winmm.dll")] static extern uint midiInStart(IntPtr h);
  [DllImport("winmm.dll")] static extern uint midiInStop(IntPtr h);
  [DllImport("winmm.dll")] static extern uint midiInReset(IntPtr h);
  [DllImport("winmm.dll")] static extern uint midiInClose(IntPtr h);
  [DllImport("winmm.dll")] static extern uint midiOutPrepareHeader(IntPtr h, IntPtr hdr, uint s);
  [DllImport("winmm.dll")] static extern uint midiOutUnprepareHeader(IntPtr h, IntPtr hdr, uint s);
  [DllImport("winmm.dll")] static extern uint midiOutLongMsg(IntPtr h, IntPtr hdr, uint s);
  [DllImport("winmm.dll")] static extern uint midiOutShortMsg(IntPtr h, uint msg);
  [DllImport("winmm.dll")] static extern uint midiOutClose(IntPtr h);

  public static ConcurrentQueue<byte[]> Q = new ConcurrentQueue<byte[]>();
  static IntPtr hin = IntPtr.Zero, hdev = IntPtr.Zero, hdst = IntPtr.Zero;
  static IntPtr[] hdrs = new IntPtr[8];
  static uint HS = (uint)Marshal.SizeOf(typeof(MIDIHDR));
  static volatile bool running;
  static Proc cb = OnMsg;

  public static string InName(uint i){ INCAPS c; midiInGetDevCaps((UIntPtr)i,out c,(uint)Marshal.SizeOf(typeof(INCAPS))); return c.name; }
  public static string OutName(uint i){ OUTCAPS c; midiOutGetDevCaps((UIntPtr)i,out c,(uint)Marshal.SizeOf(typeof(OUTCAPS))); return c.name; }

  static void OnMsg(IntPtr h, uint msg, IntPtr inst, IntPtr p1, IntPtr p2) {
    if (msg == 0x3C4) {
      MIDIHDR hd = (MIDIHDR)Marshal.PtrToStructure(p1, typeof(MIDIHDR));
      if (hd.dwBytesRecorded > 0) { byte[] b = new byte[hd.dwBytesRecorded]; Marshal.Copy(hd.lpData, b, 0, b.Length); Q.Enqueue(b); }
      if (running) midiInAddBuffer(hin, p1, HS);
    }
  }

  public static string OpenDevice(int iin, int iout) {
    uint r = midiInOpen(out hin,(uint)iin,cb,IntPtr.Zero,0x30000); if (r!=0) return "midiInOpen erro "+r+" (porta em uso? feche o BOSS TONE STUDIO)";
    r = midiOutOpen(out hdev,(uint)iout,IntPtr.Zero,IntPtr.Zero,0); if (r!=0) return "midiOutOpen erro "+r;
    for (int k=0;k<hdrs.Length;k++){
      MIDIHDR hd = new MIDIHDR(); hd.lpData = Marshal.AllocHGlobal(4096); hd.dwBufferLength=4096; hd.dwReserved=new IntPtr[8];
      hdrs[k]=Marshal.AllocHGlobal((int)HS); Marshal.StructureToPtr(hd,hdrs[k],false);
      midiInPrepareHeader(hin,hdrs[k],HS); midiInAddBuffer(hin,hdrs[k],HS);
    }
    running = true; midiInStart(hin); return "OK";
  }
  public static string OpenDest(int i) { uint r = midiOutOpen(out hdst,(uint)i,IntPtr.Zero,IntPtr.Zero,0); return r==0 ? "OK" : "midiOutOpen destino erro "+r; }
  public static bool HasDest { get { return hdst != IntPtr.Zero; } }
  public static void Short(int status, int d1, int d2) { if (hdst!=IntPtr.Zero) midiOutShortMsg(hdst, (uint)(status | (d1<<8) | (d2<<16))); }

  public static void SendSysex(byte[] data) {
    IntPtr buf = Marshal.AllocHGlobal(data.Length); Marshal.Copy(data,0,buf,data.Length);
    MIDIHDR hd = new MIDIHDR(); hd.lpData=buf; hd.dwBufferLength=(uint)data.Length; hd.dwBytesRecorded=(uint)data.Length; hd.dwReserved=new IntPtr[8];
    IntPtr p = Marshal.AllocHGlobal((int)HS); Marshal.StructureToPtr(hd,p,false);
    midiOutPrepareHeader(hdev,p,HS); midiOutLongMsg(hdev,p,HS);
    for (int i=0;i<200;i++){ MIDIHDR c=(MIDIHDR)Marshal.PtrToStructure(p,typeof(MIDIHDR)); if ((c.dwFlags & 1)!=0) break; System.Threading.Thread.Sleep(1); }
    midiOutUnprepareHeader(hdev,p,HS); Marshal.FreeHGlobal(p); Marshal.FreeHGlobal(buf);
  }
  public static void Close() {
    running=false;
    if (hin!=IntPtr.Zero){ midiInStop(hin); midiInReset(hin); foreach(var p in hdrs) if(p!=IntPtr.Zero) midiInUnprepareHeader(hin,p,HS); midiInClose(hin); }
    if (hdev!=IntPtr.Zero) midiOutClose(hdev);
    if (hdst!=IntPtr.Zero) midiOutClose(hdst);
  }
}
"@

# ---------- helpers ----------
function Req([int[]]$addr) {
  $b = $addr + @(0,0,0,0x10); [int]$s = 0; $b | ForEach-Object { $s += $_ }
  [byte[]](@(0xF0,0x41,0x10,0,0,0x45,0x11) + $b + @(((128 - ($s % 128)) % 128), 0xF7))
}
function NameOf([byte[]]$m) { if ($m.Length -lt 141) { return $null }; (-join (0..15 | ForEach-Object { [char]$m[11+97+2*$_] })).Trim() }
function AddrOf([byte[]]$m) { if ($m.Length -lt 11) { return '' }; '{0:X2} {1:X2} {2:X2} {3:X2}' -f $m[7],$m[8],$m[9],$m[10] }
function Log($s) { "{0:HH:mm:ss.fff}  {1}" -f (Get-Date), $s }
function Drain() { $out = @(); $x = $null; while ([Me25]::Q.TryDequeue([ref]$x)) { if ($x.Length -gt 7 -and $x[1] -eq 0x41 -and $x[6] -eq 0x12) { $out += ,$x } }; ,$out }

$OFF_SOLO = 11 + 85   # dado[85] no bloco do patch
$N = 60               # patches 7F 00 00 00 .. 7F 00 3B 00
$ch = [Math]::Max(1,[Math]::Min(16,$Channel)) - 1

# ---------- portas ----------
$iin = -1; $iout = -1; $idst = -1
for ($i=0; $i -lt [Me25]::midiInGetNumDevs(); $i++)  { if ([Me25]::InName($i)  -match 'ME-25') { $iin = $i; break } }
for ($i=0; $i -lt [Me25]::midiOutGetNumDevs(); $i++) {
  $portName = [Me25]::OutName($i)
  if ($portName -match 'ME-25' -and $iout -lt 0) { $iout = $i }
  elseif ($OutPort -and $portName -like "*$OutPort*" -and $idst -lt 0) { $idst = $i }
}
if ($iin -lt 0 -or $iout -lt 0) { Log "ME-25 nao encontrada. Esta ligada e com o driver instalado?"; exit 1 }
$r = [Me25]::OpenDevice($iin, $iout); if ($r -ne 'OK') { Log $r; exit 1 }
if ($idst -ge 0) { $r = [Me25]::OpenDest($idst); Log "Saida MIDI: $([Me25]::OutName($idst)) ($r)" }
else {
  Log "Porta de saida '$OutPort' nao encontrada - modo so-console. Portas disponiveis:"
  for ($i=0; $i -lt [Me25]::midiOutGetNumDevs(); $i++) { "    [$i] " + [Me25]::OutName($i) }
}

try {
  # ---------- carrega nomes dos 60 patches (para saber se subiu ou desceu) ----------
  $names = @{}
  for ($p=0; $p -lt $N; $p++) {
    [Me25]::SendSysex((Req @(0x7F,0,$p,0)))
    $t = (Get-Date).AddMilliseconds(500)
    do { Start-Sleep -Milliseconds 5; foreach ($m in (Drain)) { if ((AddrOf $m) -eq ('7F 00 {0:X2} 00' -f $p)) { $names[$p] = NameOf $m } } } while (-not $names.ContainsKey($p) -and (Get-Date) -lt $t)
  }
  Log "Patches carregados: $($names.Count)/$N"

  $reqCur = Req @(0x7F,0x7F,0,0)
  $curIdx = -1; $curName = $null; $solo = $null

  function FindIdx($name, $near) {
    $c = @($names.Keys | Where-Object { $names[$_] -eq $name })
    if ($c.Count -eq 0) { return -1 }
    if ($c.Count -eq 1 -or $near -lt 0) { return [int]$c[0] }
    # nomes repetidos (ex.: NiceClean 5 e 6): pega o mais proximo do patch anterior
    $best = $c | Sort-Object { $d = [Math]::Abs($_ - $near); [Math]::Min($d, $N - $d) } | Select-Object -First 1
    return [int]$best
  }

  Log "Rodando. Memory esq -> CC$CcDown | Memory dir -> CC$CcUp | SOLO -> CC$CcSolo | canal $Channel. Ctrl+C para sair."
  $stopAt = if ($Seconds -gt 0) { (Get-Date).AddSeconds($Seconds) } else { [DateTime]::MaxValue }
  while ((Get-Date) -lt $stopAt) {
    [Me25]::SendSysex($reqCur)
    $t = (Get-Date).AddMilliseconds(400); $got = $null
    do { Start-Sleep -Milliseconds 3; foreach ($m in (Drain)) { if ((AddrOf $m) -eq '7F 7F 00 00' -and $m.Length -ge 141) { $got = $m } } } while (-not $got -and (Get-Date) -lt $t)
    if ($got) {
      $name = NameOf $got; $s = [int]$got[$OFF_SOLO]
      if ($null -eq $curName) {
        $curName = $name; $curIdx = FindIdx $name -1; $solo = $s
        Log "Patch inicial: $($curIdx+1) '$name' | SOLO=$s"
        try { [Console]::Beep(880, 300) } catch {}
      }
      elseif ($name -ne $curName) {
        $new = FindIdx $name $curIdx
        $dir = 0
        if ($new -ge 0 -and $curIdx -ge 0) { $d = ($new - $curIdx + $N) % $N; if ($d -ne 0) { $dir = if ($d -le $N/2) { 1 } else { -1 } } }
        if ($dir -gt 0)     { [Me25]::Short(0xB0+$ch, $CcUp, 127);   [Me25]::Short(0xB0+$ch, $CcUp, 0);   $tag = "MEMORY UP   -> CC$CcUp" }
        elseif ($dir -lt 0) { [Me25]::Short(0xB0+$ch, $CcDown, 127); [Me25]::Short(0xB0+$ch, $CcDown, 0); $tag = "MEMORY DOWN -> CC$CcDown" }
        else { $tag = "PATCH (direcao desconhecida)" }
        if ($ProgramChange -and $new -ge 0) { [Me25]::Short(0xC0+$ch, $new, 0); $tag += " + PC $new" }
        Log "$tag | patch $($new+1) '$name'"
        $curName = $name; $curIdx = $new; $solo = $s   # SOLO pode mudar junto com o patch: nao gera CC
      }
      elseif ($s -ne $solo) {
        $v = if ($s -ne 0) { 127 } else { 0 }
        [Me25]::Short(0xB0+$ch, $CcSolo, $v)
        Log ("SOLO {0} -> CC{1} = {2}" -f $(if ($v) {'ON '} else {'OFF'}), $CcSolo, $v)
        $solo = $s
      }
    }
    Start-Sleep -Milliseconds $PollMs
  }
} finally { [Me25]::Close(); Log "Ponte fechada." }
