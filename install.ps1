# Installs the paredros binary from GitHub Releases on Windows.
#
#   irm https://github.com/planetis-m/paredros/releases/latest/download/install.ps1 | iex
#
# $env:PAREDROS_VERSION      release tag to install (default: the latest release)
# $env:PAREDROS_INSTALL_DIR  where to put paredros.exe (default: %LOCALAPPDATA%\Programs\paredros)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$repo = 'planetis-m/paredros'
$version = if ($env:PAREDROS_VERSION) { $env:PAREDROS_VERSION } else { 'latest' }
$dir = if ($env:PAREDROS_INSTALL_DIR) { $env:PAREDROS_INSTALL_DIR } else { Join-Path $env:LOCALAPPDATA 'Programs\paredros' }

$arch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
switch ($arch) {
  'AMD64' { }
  'ARM64' { Write-Warning 'No Windows ARM64 build is published; installing the x64 build, which needs x64 emulation.' }
  default { throw "paredros install: unsupported architecture: $arch" }
}

$base = "https://github.com/$repo/releases/download/$version"
if ($version -eq 'latest') { $base = "https://github.com/$repo/releases/latest/download" }
$asset = 'paredros-windows-amd64.zip'

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("paredros-" + [Guid]::NewGuid())
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
  Write-Host "Downloading $asset ($version)"
  Invoke-WebRequest -UseBasicParsing -Uri "$base/$asset" -OutFile (Join-Path $tmp $asset)
  Invoke-WebRequest -UseBasicParsing -Uri "$base/SHA256SUMS" -OutFile (Join-Path $tmp 'SHA256SUMS')

  $expected = $null
  foreach ($line in Get-Content (Join-Path $tmp 'SHA256SUMS')) {
    $parts = $line -split '\s+', 2
    if ($parts.Count -eq 2 -and $parts[1].TrimStart('*') -eq $asset) { $expected = $parts[0] }
  }
  if (-not $expected) { throw "paredros install: $asset is not listed in SHA256SUMS" }
  $actual = (Get-FileHash -Algorithm SHA256 (Join-Path $tmp $asset)).Hash
  if ($actual -ne $expected) { throw "paredros install: checksum mismatch for $asset" }

  Expand-Archive -Path (Join-Path $tmp $asset) -DestinationPath $tmp -Force
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $exe = Join-Path $dir 'paredros.exe'
  Copy-Item -Force (Join-Path $tmp 'paredros.exe') $exe
} finally {
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

& $exe -h | Out-Null
if ($LASTEXITCODE -ne 0) { throw "paredros install: installed $exe but it does not run" }
Write-Host "Installed paredros to $exe"

$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if (-not (($userPath -split ';') -contains $dir)) {
  $newPath = if ($userPath) { "$userPath;$dir" } else { $dir }
  [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
  $env:Path = "$env:Path;$dir"
  Write-Host "Added $dir to your user PATH; open a new terminal to use paredros."
}
