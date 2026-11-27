param(
    [string]$Python = "python",
    [string]$DistDirectory,
    [switch]$SkipDependencyInstall
)

$ErrorActionPreference = "Stop"
if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
    $PSNativeCommandUseErrorActionPreference = $true
}

function Invoke-Python {
    & $Python @args
    if ($LASTEXITCODE -ne 0) {
        throw "Python build command failed with exit code $LASTEXITCODE"
    }
}

Push-Location $PSScriptRoot
try {
    $architecture = Invoke-Python -c "import sys, platform; print(f'{sys.version_info.major}.{sys.version_info.minor} {platform.machine()}')"
    if ($architecture -ne "3.12 AMD64") {
        throw "Build with a clean Windows x64 CPython 3.12 environment. Detected $architecture."
    }
    if (-not $SkipDependencyInstall) {
        Invoke-Python -m pip install --disable-pip-version-check -r requirements-dev.txt
    }
    Invoke-Python -m pytest -q

    $repo = Split-Path $PSScriptRoot
    if (-not $DistDirectory) {
        $DistDirectory = Join-Path $repo "dist"
    }
    $versionLabel = Invoke-Python -c "import sys; sys.path.insert(0, 'src'); from gaojiezou.version import VERSION_LABEL; print(VERSION_LABEL)"
    $major, $minor, $build = $versionLabel -split '[.+]'
    $version = "$major.$minor"
    $stage = Join-Path $repo "build.noindex\windows-$versionLabel"
    $frozen = Join-Path $stage "frozen"
    $macAssets = Join-Path $stage "mac-assets"
    New-Item -Path $frozen, $macAssets, $DistDirectory -ItemType Directory -Force | Out-Null

    $resources = Join-Path $repo "Resources"
    $renderedScenes = @("FarmGameSceneV15.png", "PastureGameSceneV15.png", "FishingGameSceneV15.png", "AquariumGameSceneV15.png", "AquariumPanoramaV352.png")
    $atlases = @("CropAtlasV15.png", "CropYoungAtlasV15.png", "AnimalAtlasV23.png", "AnimalYoungAtlasV23.png")
    foreach ($name in (@("GaoJieZouIcon.png") + $renderedScenes + $atlases)) {
        Copy-Item -LiteralPath (Join-Path $resources $name) -Destination $macAssets -Force
    }
    foreach ($name in @("EstateMeadowV352.png", "WorldMaterialsV357.png", "FoliageV357.png")) {
        Copy-Item -LiteralPath (Join-Path $repo "GameWorld\Resources\$name") -Destination $macAssets -Force
    }
    Get-ChildItem -LiteralPath $resources -Filter "Fish-*-V15.png" | Copy-Item -Destination $macAssets -Force
    Copy-Item -LiteralPath (Join-Path $resources "en.lproj\Localizable.strings") -Destination $macAssets -Force
    Copy-Item -LiteralPath (Join-Path $repo "Integrated\Health\Resources\IslandSceneArt.png") -Destination $macAssets -Force

    $icon = Join-Path $stage "GaoJieZou.ico"
    Add-Type -AssemblyName System.Drawing
    $image = [System.Drawing.Image]::FromFile((Join-Path $macAssets "GaoJieZouIcon.png"))
    $writer = [System.IO.BinaryWriter]::new([IO.File]::Create($icon))
    try {
        $sizes = @(16, 32, 48, 256)
        $writer.Write([uint16]0)
        $writer.Write([uint16]1)
        $writer.Write([uint16]$sizes.Count)
        $offset = 6 + 16 * $sizes.Count
        $frames = @()
        foreach ($size in $sizes) {
            $bitmap = [System.Drawing.Bitmap]::new($size, $size)
            $canvas = [System.Drawing.Graphics]::FromImage($bitmap)
            $png = [System.IO.MemoryStream]::new()
            try {
                $canvas.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                $canvas.DrawImage($image, 0, 0, $size, $size)
                $bitmap.Save($png, [System.Drawing.Imaging.ImageFormat]::Png)
                $bytes = $png.ToArray()
                $frames += ,$bytes
                $writer.Write([byte]($size % 256))
                $writer.Write([byte]($size % 256))
                $writer.Write([uint16]0)
                $writer.Write([uint16]1)
                $writer.Write([uint16]32)
                $writer.Write([uint32]$bytes.Length)
                $writer.Write([uint32]$offset)
                $offset += $bytes.Length
            }
            finally {
                $png.Dispose()
                $canvas.Dispose()
                $bitmap.Dispose()
            }
        }
        foreach ($frame in $frames) {
            $writer.Write([byte[]]$frame)
        }
    }
    finally {
        $writer.Dispose()
        $image.Dispose()
    }

    $versionFile = Join-Path $stage "version.txt"
    $versionResource = @"
VSVersionInfo(
  ffi=FixedFileInfo(filevers=($major, $minor, 0, $build), prodvers=($major, $minor, 0, $build),
                    mask=0x3f, flags=0, OS=0x40004, fileType=1, subtype=0, date=(0, 0)),
  kids=[StringFileInfo([StringTable('040904b0', [
    StringStruct('CompanyName', 'GaoSeries'),
    StringStruct('FileDescription', 'GaoJieZou Rhythm'),
    StringStruct('FileVersion', '$version.$build'),
    StringStruct('InternalName', 'GaoJieZou'),
    StringStruct('ProductName', 'GaoJieZou Rhythm'),
    StringStruct('ProductVersion', '$version.$build')
  ])]), VarFileInfo([VarStruct('Translation', [0x0409, 1200])])])
"@
    [IO.File]::WriteAllText($versionFile, $versionResource, [Text.UTF8Encoding]::new($false))

    $platformFiles = (Join-Path $PSScriptRoot "src\gaojiezou\assets") + ";gaojiezou_assets"
    $artFiles = $macAssets + ";mac-assets"
    foreach ($flavor in @("cli", "gui")) {
        $name = if ($flavor -eq "gui") { "GaoJieZou" } else { "GaoJieZou-cli" }
        $mode = if ($flavor -eq "gui") { "--windowed" } else { "--console" }
        $flavorStage = Join-Path $stage $flavor
        Invoke-Python -m PyInstaller --noconfirm --clean --name $name $mode --onefile --paths src --add-data $platformFiles `
            --add-data $artFiles --collect-data tzdata --collect-submodules winrt --copy-metadata winrt-runtime `
            --copy-metadata winrt-Windows.Data.Xml.Dom --copy-metadata winrt-Windows.Foundation.Collections `
            --copy-metadata winrt-Windows.UI.Notifications --icon $icon --version-file $versionFile `
            --distpath $frozen --workpath $flavorStage --specpath $flavorStage launch.py
    }

    $artifactName = "GaoJieZou-$versionLabel-Windows-x64.msi"
    $stagedInstaller = Join-Path $stage $artifactName
    Invoke-Python installer.py --output $stagedInstaller --payload $frozen --icon $icon
    $installer = Join-Path $DistDirectory $artifactName
    Copy-Item -LiteralPath $stagedInstaller -Destination $installer -Force
    $hash = (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash.ToLowerInvariant()
    Set-Content -LiteralPath "$installer.sha256" -Value "$hash  $artifactName" -Encoding ascii
    Get-Item -LiteralPath $installer, "$installer.sha256" | Select-Object FullName, Length
}
finally {
    Pop-Location
}
