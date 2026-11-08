param(
  [Parameter(Mandatory=$true)][string]$Version,
  [Parameter(Mandatory=$true)][string]$PrivateKeyPath,
  [string]$RemoteFolder = 'disk:/VibeNote'
)
$ErrorActionPreference = 'Stop'
# Set YANDEX_DISK_TOKEN in the local process environment; never pass it on the command line.
if (!$env:YANDEX_DISK_TOKEN) { throw 'Set YANDEX_DISK_TOKEN locally. Do not commit or share it.' }
$headers = @{ Authorization = "OAuth $env:YANDEX_DISK_TOKEN" }
$api = 'https://cloud-api.yandex.net/v1/disk'
function Escape([string]$value) { [Uri]::EscapeDataString($value) }
function ReadResource([string]$path) {
  Invoke-RestMethod -Uri "$api/resources?path=$(Escape $path)" -Headers $headers
}
$root = ReadResource $RemoteFolder
if ($root.public_url -notmatch '/wGSbdk-DsW0JrQ$') { throw 'RemoteFolder does not match the configured public mirror' }
& dart run tools/mirror_manifest.dart $PrivateKeyPath $Version
if ($LASTEXITCODE -ne 0) { throw 'Manifest preparation failed' }
$folder = "$RemoteFolder/$Version"
try { $null = Invoke-RestMethod -Method Put -Uri "$api/resources?path=$(Escape $folder)" -Headers $headers }
catch { if ([int]$_.Exception.Response.StatusCode -ne 409) { throw } }
$manifest = Get-Content release/latest.json -Raw | ConvertFrom-Json
$payload = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($manifest.payload)) | ConvertFrom-Json
function Upload([string]$local, [string]$remote, [bool]$overwrite) {
  $upload = Invoke-RestMethod -Uri "$api/resources/upload?path=$(Escape $remote)&overwrite=$($overwrite.ToString().ToLower())" -Headers $headers
  $null = Invoke-WebRequest -UseBasicParsing -Method Put -Uri $upload.href -InFile $local -ContentType 'application/octet-stream'
  $info = ReadResource $remote
  $file = Get-Item $local
  if ($info.size -ne $file.Length -or $info.sha256 -ne (Get-FileHash $local -Algorithm SHA256).Hash.ToLower()) {
    throw 'Uploaded file verification failed; latest.json was not published'
  }
}
foreach ($asset in $payload.assets) {
  $remote = "$RemoteFolder$($asset.path)"
  # Version directories are immutable. Existing identical files allow a safe retry.
  $existing = $null
  try { $existing = ReadResource $remote } catch { if ([int]$_.Exception.Response.StatusCode -ne 404) { throw } }
  if ($existing) {
    if ($existing.size -ne $asset.size -or "sha256:$($existing.sha256)" -ne $asset.digest) { throw 'Version already exists with different content' }
  } else { Upload "release/$($asset.name)" $remote $false }
}
Upload 'release/latest.json' "$RemoteFolder/latest.json" $true
Write-Output 'Mirror published and verified. latest.json updated last.'
