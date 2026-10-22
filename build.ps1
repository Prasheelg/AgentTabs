#Requires -Version 5.1
<#
  Builds dist\ClaudeLauncher.exe: a small native stub with ClaudeLauncher.ps1 embedded.
  On run it copies the script to %LOCALAPPDATA%\ClaudeLauncher and starts it headless (no console flash).
  Uses the C# compiler that ships with .NET Framework 4, so nothing needs to be installed.
#>

$ErrorActionPreference = 'Stop'
$root   = $PSScriptRoot
$src    = Join-Path $root 'ClaudeLauncher.ps1'
$dist   = Join-Path $root 'dist'
$obj    = Join-Path $dist 'obj'
$csc    = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) 'csc.exe'
New-Item -ItemType Directory -Force $obj | Out-Null

# --- Icon: render the app's own AppIcon (from the script's UI types) into a multi-size .ico ---
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$blocks = [regex]::Matches((Get-Content $src -Raw), "(?s)-TypeDefinition @'\r?\n(.*?)\r?\n'@")
$ui = $blocks | Where-Object { $_.Groups[1].Value -match 'class Glyphs' } | Select-Object -First 1
if (-not $ui) { throw 'Could not find the Glyphs class in ClaudeLauncher.ps1' }
Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition $ui.Groups[1].Value

$sizes = 16, 24, 32, 48, 64, 256
$pngs  = foreach ($s in $sizes) {
    $ms = New-Object IO.MemoryStream
    ([Glyphs]::AppIcon($s)).Save($ms, [Drawing.Imaging.ImageFormat]::Png)
    , $ms.ToArray()
}
$ico = Join-Path $obj 'ClaudeLauncher.ico'
$fs  = [IO.File]::Create($ico); $bw = New-Object IO.BinaryWriter $fs
$bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $d = if ($sizes[$i] -ge 256) { 0 } else { $sizes[$i] }   # 0 means 256 in an ICONDIRENTRY
    $bw.Write([byte]$d); $bw.Write([byte]$d); $bw.Write([byte]0); $bw.Write([byte]0)
    $bw.Write([uint16]1); $bw.Write([uint16]32)
    $bw.Write([uint32]$pngs[$i].Length); $bw.Write([uint32]$offset)
    $offset += $pngs[$i].Length
}
foreach ($p in $pngs) { $bw.Write($p) }
$bw.Close()

# --- Stub ---
$stub = Join-Path $obj 'Stub.cs'
Set-Content $stub -Encoding utf8 -Value @'
using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Windows.Forms;

[assembly: AssemblyTitle("Claude Launcher")]
[assembly: AssemblyProduct("Claude Launcher")]
[assembly: AssemblyVersion("1.0.0.0")]

static class Program {
    [STAThread]
    static int Main() {
        try {
            byte[] data;
            using (var s = Assembly.GetExecutingAssembly().GetManifestResourceStream("ClaudeLauncher.ps1"))
            using (var ms = new MemoryStream()) { s.CopyTo(ms); data = ms.ToArray(); }

            string dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ClaudeLauncher");
            Directory.CreateDirectory(dir);
            string script = Path.Combine(dir, "ClaudeLauncher.ps1");
            if (!File.Exists(script) || !File.ReadAllBytes(script).SequenceEqual(data)) File.WriteAllBytes(script, data);

            // conhost --headless gives PowerShell a console without ever creating a window (and keeps Windows Terminal out of it).
            string sys = Environment.SystemDirectory;
            string ps = Path.Combine(sys, @"WindowsPowerShell\v1.0\powershell.exe");
            var psi = new ProcessStartInfo(Path.Combine(sys, "conhost.exe"),
                "--headless \"" + ps + "\" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File \"" + script + "\"");
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            Process.Start(psi);
            return 0;
        } catch (Exception ex) {
            MessageBox.Show("Could not start Claude Launcher:\n\n" + ex.Message, "Claude Launcher", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }
}
'@

$exe = Join-Path $dist 'ClaudeLauncher.exe'
& $csc /nologo /target:winexe /platform:anycpu /optimize+ "/out:$exe" "/win32icon:$ico" `
    "/resource:$src,ClaudeLauncher.ps1" /r:System.Windows.Forms.dll /r:System.Core.dll $stub
if ($LASTEXITCODE -ne 0) { throw "csc failed ($LASTEXITCODE)" }
Remove-Item -Recurse -Force $obj
Write-Host "Built $exe"
