param(
  [int]$Seconds = 5,
  [string]$Match = 'ME-25',
  # Mensagens SysEx (hex) a enviar ao abrir, separadas por ';'. Padrao: Universal Identity Request.
  [string]$Send = 'F0 7E 7F 06 01 F7',
  # Se > 0, reenvia $Send a cada N ms e so mostra respostas que mudaram (diff byte a byte).
  [int]$PollMs = 0
)
# Abre a entrada/saida MIDI da ME-25, envia SysEx e mostra tudo que chegar (curto e SysEx).
Add-Type -TypeDefinition @"
using System;
using System.Collections.Concurrent;
using System.Runtime.InteropServices;
public static class MidiProbe {
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
  [DllImport("winmm.dll")] static extern uint midiInGetNumDevs();
  [DllImport("winmm.dll")] static extern uint midiOutGetNumDevs();
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
  [DllImport("winmm.dll")] static extern uint midiOutClose(IntPtr h);

  public static ConcurrentQueue<string> Q = new ConcurrentQueue<string>();
  static IntPtr hin = IntPtr.Zero, hout = IntPtr.Zero;
  static IntPtr[] hdrs = new IntPtr[8];
  static uint HS = (uint)Marshal.SizeOf(typeof(MIDIHDR));
  static volatile bool running;
  static Proc cb = OnMsg;

  static string Hex(byte[] b, int n){ var s = new System.Text.StringBuilder(); for(int i=0;i<n;i++) s.AppendFormat("{0:X2} ", b[i]); return s.ToString().Trim(); }

  static void OnMsg(IntPtr h, uint msg, IntPtr inst, IntPtr p1, IntPtr p2) {
    if (msg == 0x3C3) { uint d=(uint)p1.ToInt64(); byte s=(byte)(d&0xFF); if (s==0xFE||s==0xF8) return;
      Q.Enqueue(String.Format("SHORT {0:X2} {1:X2} {2:X2}", s, (d>>8)&0xFF, (d>>16)&0xFF)); }
    else if (msg == 0x3C4) { // MIM_LONGDATA
      MIDIHDR hd = (MIDIHDR)Marshal.PtrToStructure(p1, typeof(MIDIHDR));
      if (hd.dwBytesRecorded > 0) { byte[] b = new byte[hd.dwBytesRecorded]; Marshal.Copy(hd.lpData, b, 0, b.Length); Q.Enqueue("SYSEX " + Hex(b, b.Length)); }
      if (running) midiInAddBuffer(hin, p1, HS);
    }
    else if (msg == 0x3C5 || msg == 0x3C6) Q.Enqueue("ERROR msg=0x" + msg.ToString("X"));
  }

  public static string Open(string match) {
    int iin=-1, iout=-1;
    for (uint i=0;i<midiInGetNumDevs();i++){ INCAPS c; midiInGetDevCaps((UIntPtr)i,out c,(uint)Marshal.SizeOf(typeof(INCAPS))); if (c.name.Contains(match)) { iin=(int)i; break; } }
    for (uint i=0;i<midiOutGetNumDevs();i++){ OUTCAPS c; midiOutGetDevCaps((UIntPtr)i,out c,(uint)Marshal.SizeOf(typeof(OUTCAPS))); if (c.name.Contains(match)) { iout=(int)i; break; } }
    if (iin<0||iout<0) return "porta nao encontrada (in="+iin+", out="+iout+")";
    uint r = midiInOpen(out hin,(uint)iin,cb,IntPtr.Zero,0x30000); if (r!=0) return "midiInOpen erro "+r+" (porta em uso?)";
    r = midiOutOpen(out hout,(uint)iout,IntPtr.Zero,IntPtr.Zero,0); if (r!=0) return "midiOutOpen erro "+r+" (porta em uso?)";
    for (int k=0;k<hdrs.Length;k++){
      MIDIHDR hd = new MIDIHDR(); hd.lpData = Marshal.AllocHGlobal(4096); hd.dwBufferLength=4096; hd.dwReserved=new IntPtr[8];
      hdrs[k]=Marshal.AllocHGlobal((int)HS); Marshal.StructureToPtr(hd,hdrs[k],false);
      midiInPrepareHeader(hin,hdrs[k],HS); midiInAddBuffer(hin,hdrs[k],HS);
    }
    running = true; midiInStart(hin);
    return "OK in="+iin+" out="+iout;
  }

  public static string SendSysex(byte[] data) {
    IntPtr buf = Marshal.AllocHGlobal(data.Length); Marshal.Copy(data,0,buf,data.Length);
    MIDIHDR hd = new MIDIHDR(); hd.lpData=buf; hd.dwBufferLength=(uint)data.Length; hd.dwBytesRecorded=(uint)data.Length; hd.dwReserved=new IntPtr[8];
    IntPtr p = Marshal.AllocHGlobal((int)HS); Marshal.StructureToPtr(hd,p,false);
    midiOutPrepareHeader(hout,p,HS); uint r = midiOutLongMsg(hout,p,HS);
    for (int i=0;i<200;i++){ MIDIHDR c=(MIDIHDR)Marshal.PtrToStructure(p,typeof(MIDIHDR)); if ((c.dwFlags & 1)!=0) break; System.Threading.Thread.Sleep(5); }
    midiOutUnprepareHeader(hout,p,HS); Marshal.FreeHGlobal(p); Marshal.FreeHGlobal(buf);
    return r==0 ? "enviado: "+Hex(data,data.Length) : "midiOutLongMsg erro "+r;
  }

  public static void Close() {
    running=false;
    if (hin!=IntPtr.Zero){ midiInStop(hin); midiInReset(hin); foreach(var p in hdrs) if(p!=IntPtr.Zero) midiInUnprepareHeader(hin,p,HS); midiInClose(hin); }
    if (hout!=IntPtr.Zero) midiOutClose(hout);
  }
}
"@

"Abrindo: " + [MidiProbe]::Open($Match)
if ($PollMs -gt 0) {
  try {
    $reqs = @($Send -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | ForEach-Object { ,[byte[]]($_ -split '\s+' | ForEach-Object { [Convert]::ToByte($_,16) }) })
    $prev = @{}; $n = 0
    "Polling de $($reqs.Count) endereco(s) a cada $PollMs ms por $Seconds s..."
    $t0 = Get-Date; $end = $t0.AddSeconds($Seconds)
    while ((Get-Date) -lt $end) {
      foreach ($r in $reqs) { [void][MidiProbe]::SendSysex($r); $n++; Start-Sleep -Milliseconds 15 }
      Start-Sleep -Milliseconds $PollMs
      $x=$null
      while ([MidiProbe]::Q.TryDequeue([ref]$x)) {
        $el = "{0,5:N1}s" -f ((Get-Date) - $t0).TotalSeconds
        if ($x -notlike 'SYSEX*') { "$el  $x"; continue }
        $cur = $x.Substring(6) -split ' '
        $key = if ($cur.Count -gt 10) { ($cur[7..10] -join ' ') } else { 'curto' }
        $p = $prev[$key]
        if ($null -eq $p) { "$el  INICIAL [$key] ($($cur.Count) bytes): $($cur -join ' ')" }
        elseif (($cur -join ' ') -ne ($p -join ' ')) {
          $d = for ($i=11; $i -lt [Math]::Min($cur.Count,$p.Count)-2; $i++) { if ($cur[$i] -ne $p[$i]) { "dado[$($i-11)] $($p[$i])->$($cur[$i])" } }
          if ($cur.Count -ne $p.Count) { $d += "tamanho $($p.Count)->$($cur.Count)" }
          $nm = ''
          if ($cur.Count -ge 133) { $nm = -join (0..15 | ForEach-Object { [char][Convert]::ToInt32($cur[11+97+2*$_],16) }) }
          if (@($d).Count -gt 8 -and $nm) { "$el  PATCH -> '$($nm.Trim())' ($(@($d).Count) params)" }
          else {
            $dd = $d | ForEach-Object { if ($_ -match 'dado\[(\d+)\] (\w\w)->(\w\w)') { "d$($matches[1]): $([Convert]::ToInt32($matches[2],16))->$([Convert]::ToInt32($matches[3],16))" } else { $_ } }
            "$el  MUDOU: $($dd -join ', ')"
          }
        }
        $prev[$key] = $cur
      }
    }
    "Requisicoes enviadas: $n"
  } finally { [MidiProbe]::Close(); "Fim." }
  return
}
try {
  foreach ($m in ($Send -split ';')) {
    $m = $m.Trim(); if (-not $m) { continue }
    $bytes = [byte[]]($m -split '\s+' | ForEach-Object { [Convert]::ToByte($_,16) })
    [MidiProbe]::SendSysex($bytes)
    Start-Sleep -Milliseconds 300
  }
  "Escutando por $Seconds s..."
  $end = (Get-Date).AddSeconds($Seconds)
  while ((Get-Date) -lt $end) {
    $x=$null; while ([MidiProbe]::Q.TryDequeue([ref]$x)) { "{0:HH:mm:ss.fff}  {1}" -f (Get-Date), $x }
    Start-Sleep -Milliseconds 20
  }
  $x=$null; while ([MidiProbe]::Q.TryDequeue([ref]$x)) { "{0:HH:mm:ss.fff}  {1}" -f (Get-Date), $x }
} finally { [MidiProbe]::Close(); "Fim." }
