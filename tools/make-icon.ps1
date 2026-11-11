# Gera app.ico (16, 24, 32, 48, 64, 128, 256 px): conector MIDI DIN em ambar sobre fundo escuro arredondado.
Add-Type -AssemblyName System.Drawing
$assets = Join-Path (Split-Path $PSScriptRoot -Parent) 'assets'
$out = Join-Path $assets 'app.ico'
$sizes = 16, 24, 32, 48, 64, 128, 256

function RoundRect([float]$x, [float]$y, [float]$w, [float]$h, [float]$r) {
  $p = New-Object System.Drawing.Drawing2D.GraphicsPath
  $d = 2 * $r
  $p.AddArc($x, $y, $d, $d, 180, 90); $p.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
  $p.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90); $p.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
  $p.CloseFigure(); $p
}

$pngs = foreach ($s in $sizes) {
  $bmp = New-Object System.Drawing.Bitmap $s, $s, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = 'AntiAlias'; $g.PixelOffsetMode = 'HighQuality'; $g.Clear([System.Drawing.Color]::Transparent)
  $k = $s / 256.0

  # fundo
  $bg = RoundRect (4*$k) (4*$k) (248*$k) (248*$k) (52*$k)
  $br = New-Object System.Drawing.Drawing2D.LinearGradientBrush ([System.Drawing.PointF]::new(0,0)), ([System.Drawing.PointF]::new(0,$s)), ([System.Drawing.Color]::FromArgb(255,52,52,60)), ([System.Drawing.Color]::FromArgb(255,22,22,26))
  $g.FillPath($br, $bg)

  $amber = [System.Drawing.Color]::FromArgb(255, 255, 166, 0)
  $c = 128 * $k; $R = 84 * $k
  # anel do conector
  $pen = New-Object System.Drawing.Pen $amber, ([Math]::Max(1.5, 18 * $k))
  $g.DrawEllipse($pen, $c - $R, $c - $R, 2*$R, 2*$R)
  # entalhe no topo
  $nb = New-Object System.Drawing.SolidBrush $amber
  $g.FillRectangle($nb, $c - 14*$k, $c - $R - 10*$k, 28*$k, 30*$k)
  # 5 pinos em arco (180 graus, parte de baixo) - em tamanhos pequenos so 3
  # 5 pinos num arco de 180 graus na metade de baixo (y cresce para baixo); em 16-24 px so 3
  $pins = if ($s -lt 32) { @(0, 90, 180) } else { @(0, 45, 90, 135, 180) }
  $pr = [Math]::Max(1.6, 12 * $k); $pd = 48 * $k; $cy = $c - 6*$k
  foreach ($a in $pins) {
    $rad = $a * [Math]::PI / 180
    $x = $c + $pd * [Math]::Cos($rad); $y = $cy + $pd * [Math]::Sin($rad)
    $g.FillEllipse($nb, $x - $pr, $y - $pr, 2*$pr, 2*$pr)
  }

  $g.Dispose()
  $ms = New-Object System.IO.MemoryStream
  $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
  ,$ms.ToArray()
}

# monta o .ico (PNG embutido em cada entrada)
$fs = [System.IO.File]::Create($out); $w = New-Object System.IO.BinaryWriter $fs
$w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
  $s = $sizes[$i]; $b = if ($s -ge 256) { 0 } else { $s }
  $w.Write([byte]$b); $w.Write([byte]$b); $w.Write([byte]0); $w.Write([byte]0)
  $w.Write([uint16]1); $w.Write([uint16]32); $w.Write([uint32]$pngs[$i].Length); $w.Write([uint32]$offset)
  $offset += $pngs[$i].Length
}
foreach ($p in $pngs) { $w.Write($p) }
$w.Close()
"Gerado: $out"

# preview grande para conferir
$prev = Join-Path $assets 'icon.png'
[System.IO.File]::WriteAllBytes($prev, $pngs[-1]); "Preview: $prev"
