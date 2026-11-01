# Builds a single-file portable NoteVibe for Windows: release\NoteVibe-<version>-portable.exe
# Usage (from the project root):  powershell -File tools\portable\build_portable.ps1
param([switch]$SkipFlutterBuild)
$ErrorActionPreference = 'Stop'
$root = Resolve-Path "$PSScriptRoot\..\.."
Set-Location $root

$version = (Select-String -Path pubspec.yaml -Pattern '^version:\s*([^+\s]+)').Matches[0].Groups[1].Value
if (-not $SkipFlutterBuild) {
    flutter build windows --release
    if ($LASTEXITCODE -ne 0) { throw 'flutter build failed' }
}
$rel = "build\windows\x64\runner\Release"
$work = "build\portable"
if (Test-Path $work) { Remove-Item -Recurse -Force $work }
New-Item -ItemType Directory -Force "$work\app" | Out-Null
Copy-Item "$rel\*" "$work\app" -Recurse

# App-local VC++ runtime, so it starts on a clean Windows without the redistributable.
foreach ($dll in 'msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll') {
    Copy-Item "$env:WINDIR\System32\$dll" "$work\app\$dll"
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::CreateFromDirectory((Resolve-Path "$work\app"), "$root\$work\payload.zip",
    [IO.Compression.CompressionLevel]::Optimal, $false)
$hash = (Get-FileHash "$work\payload.zip" -Algorithm SHA256).Hash.Substring(0, 12).ToLower()
Set-Content "$work\payload.id" "$version-$hash" -NoNewline

New-Item -ItemType Directory -Force release | Out-Null
$out = "release\NoteVibe-$version-portable.exe"
$csc = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
& $csc /nologo /target:winexe /optimize+ /platform:x64 "/out:$out" `
    /win32icon:windows\runner\resources\app_icon.ico `
    /reference:System.IO.Compression.dll /reference:System.IO.Compression.FileSystem.dll /reference:System.Windows.Forms.dll `
    "/resource:$work\payload.zip,payload.zip" "/resource:$work\payload.id,payload.id" `
    tools\portable\Launcher.cs
if ($LASTEXITCODE -ne 0) { throw 'launcher compile failed' }
Get-Item $out | Select-Object Name, @{n = 'MB'; e = { [math]::Round($_.Length / 1MB, 1) } }
