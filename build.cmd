@echo off
rem Compila o ME-25 MIDI com o csc do .NET Framework 4 (ja incluso no Windows 10/11).
rem Saida: bin\ME25MIDI.exe
cd /d "%~dp0"
if not exist bin mkdir bin
"%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe" /nologo /target:winexe /platform:x64 /optimize+ /codepage:65001 ^
  /win32icon:assets\app.ico /out:bin\ME25MIDI.exe /r:System.Windows.Forms.dll /r:System.Drawing.dll src\Program.cs
if errorlevel 1 exit /b 1
echo OK: bin\ME25MIDI.exe
