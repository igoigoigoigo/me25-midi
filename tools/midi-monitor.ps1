param([int]$Seconds = 0, [string]$Match = 'ME-25')
# Lista portas MIDI (WinMM) e, se -Seconds > 0, monitora as entradas que contem $Match.
Add-Type -TypeDefinition @"
using System;
using System.Collections.Concurrent;
using System.Runtime.InteropServices;
public static class WinMidi {
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Auto)]
  public struct MIDIINCAPS { public ushort wMid, wPid; public uint vDriverVersion;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string szPname; public uint dwSupport; }
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Auto)]
  public struct MIDIOUTCAPS { public ushort wMid, wPid; public uint vDriverVersion;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string szPname;
    public ushort wTechnology, wVoices, wNotes, wChannelMask; public uint dwSupport; }
  public delegate void MidiInProc(IntPtr h, uint msg, IntPtr inst, IntPtr p1, IntPtr p2);
  [DllImport("winmm.dll")] public static extern uint midiInGetNumDevs();
  [DllImport("winmm.dll")] public static extern uint midiOutGetNumDevs();
  [DllImport("winmm.dll", CharSet=CharSet.Auto)] public static extern uint midiInGetDevCaps(UIntPtr id, out MIDIINCAPS c, uint sz);
  [DllImport("winmm.dll", CharSet=CharSet.Auto)] public static extern uint midiOutGetDevCaps(UIntPtr id, out MIDIOUTCAPS c, uint sz);
  [DllImport("winmm.dll")] public static extern uint midiInOpen(out IntPtr h, uint id, MidiInProc cb, IntPtr inst, uint flags);
  [DllImport("winmm.dll")] public static extern uint midiInStart(IntPtr h);
  [DllImport("winmm.dll")] public static extern uint midiInStop(IntPtr h);
  [DllImport("winmm.dll")] public static extern uint midiInClose(IntPtr h);
  public static ConcurrentQueue<string> Q = new ConcurrentQueue<string>();
  public static MidiInProc Cb = (h, msg, inst, p1, p2) => {
    if (msg == 0x3C3) { // MIM_DATA
      uint d = (uint)p1.ToInt64();
      Q.Enqueue(String.Format("{0} {1:X2} {2:X2} {3:X2}", inst, d & 0xFF, (d >> 8) & 0xFF, (d >> 16) & 0xFF));
    } else if (msg == 0x3C4 || msg == 0x3C6) { Q.Enqueue(inst + " (sysex/longdata)"); }
  };
  public static string InName(uint i){ MIDIINCAPS c; midiInGetDevCaps((UIntPtr)i, out c, (uint)Marshal.SizeOf(typeof(MIDIINCAPS))); return c.szPname; }
  public static string OutName(uint i){ MIDIOUTCAPS c; midiOutGetDevCaps((UIntPtr)i, out c, (uint)Marshal.SizeOf(typeof(MIDIOUTCAPS))); return c.szPname; }
}
"@

$nIn = [WinMidi]::midiInGetNumDevs(); $nOut = [WinMidi]::midiOutGetNumDevs()
"MIDI IN ($nIn):";  for ($i=0; $i -lt $nIn;  $i++) { "  [$i] " + [WinMidi]::InName($i) }
"MIDI OUT ($nOut):"; for ($i=0; $i -lt $nOut; $i++) { "  [$i] " + [WinMidi]::OutName($i) }
if ($Seconds -le 0) { return }

function Describe($s, $d1, $d2) {
  $t = $s -band 0xF0; $ch = ($s -band 0x0F) + 1
  switch ($t) {
    0x90 { "Note On  ch$ch note=$d1 vel=$d2" }
    0x80 { "Note Off ch$ch note=$d1" }
    0xB0 { "Control Change ch$ch CC#$d1 = $d2" }
    0xC0 { "Program Change ch$ch PC=$d1 (patch $($d1+1))" }
    0xE0 { "Pitch Bend ch$ch" }
    default { "status 0x{0:X2}" -f $s }
  }
}

$handles = @()
for ($i=0; $i -lt $nIn; $i++) {
  $name = [WinMidi]::InName($i)
  if ($name -match $Match) {
    $h = [IntPtr]::Zero
    $r = [WinMidi]::midiInOpen([ref]$h, $i, [WinMidi]::Cb, [IntPtr]$i, 0x30000) # CALLBACK_FUNCTION
    if ($r -ne 0) { "Falha ao abrir [$i] $name (erro $r - porta em uso por outro programa?)"; continue }
    [void][WinMidi]::midiInStart($h); $handles += $h; "Monitorando [$i] $name"
  }
}
if (-not $handles) { "Nenhuma porta de entrada com '$Match'."; return }
"Pise nos footswitches, troque de patch e mexa no pedal por $Seconds s..."
$end = (Get-Date).AddSeconds($Seconds)
while ((Get-Date) -lt $end) {
  $m = $null
  while ([WinMidi]::Q.TryDequeue([ref]$m)) {
    $p = $m.Split(' ')
    if ($p.Count -eq 4) {
      $s=[Convert]::ToInt32($p[1],16); $a=[Convert]::ToInt32($p[2],16); $b=[Convert]::ToInt32($p[3],16)
      if ($s -eq 0xFE -or $s -eq 0xF8) { continue } # ignora active sensing / clock
      "{0:HH:mm:ss.fff} [{1}] {2} {3} {4}  ->  {5}" -f (Get-Date), $p[0], $p[1], $p[2], $p[3], (Describe $s $a $b)
    } else { "{0:HH:mm:ss.fff} [{1}]" -f (Get-Date), $m }
  }
  Start-Sleep -Milliseconds 20
}
foreach ($h in $handles) { [void][WinMidi]::midiInStop($h); [void][WinMidi]::midiInClose($h) }
"Fim."
