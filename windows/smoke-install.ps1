param(
    [Parameter(Mandatory = $true)][string]$Package,
    [string]$ExistingCli,
    [switch]$CheckShell
)

$ErrorActionPreference = "Stop"
$msi = (Get-Item -LiteralPath $Package).FullName
$expectedHash = ((Get-Content -LiteralPath "$msi.sha256" -Raw).Trim() -split '\s+')[0]
if ((Get-FileHash -LiteralPath $msi -Algorithm SHA256).Hash -ne $expectedHash) { throw "MSI SHA-256 mismatch." }
$installer = New-Object -ComObject WindowsInstaller.Installer
$db = $installer.GetType().InvokeMember("OpenDatabase", "InvokeMethod", $null, $installer, @($msi, 0))
$statement = 'SELECT `Value` FROM `Property` WHERE `Property` = ''ProductCode'''
$view = $db.GetType().InvokeMember("OpenView", "InvokeMethod", $null, $db, @($statement))
$view.GetType().InvokeMember("Execute", "InvokeMethod", $null, $view, @())
$record = $view.GetType().InvokeMember("Fetch", "InvokeMethod", $null, $view, @())
$product = $record.GetType().InvokeMember("StringData", "GetProperty", $null, $record, @(1))
$view.GetType().InvokeMember("Close", "InvokeMethod", $null, $view, @())
[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($db)
$prior = $installer.GetType().InvokeMember("ProductState", "GetProperty", $null, $installer, @($product))
if ($prior -gt 0) { throw "This MSI product is already registered. The smoke test will leave it installed." }

$programMenu = Join-Path ([Environment]::GetFolderPath("Programs")) "GaoJieZou"
$protocol = "Registry::HKEY_CURRENT_USER\Software\Classes\gaojiezou"
$appModelID = "GaoSeries.GaoJieZou.Rhythm"
$appIdentity = "Registry::HKEY_CURRENT_USER\Software\Classes\AppUserModelId\$appModelID"
if ($CheckShell -and ((Test-Path -LiteralPath $programMenu) -or (Test-Path -LiteralPath $protocol) -or (Test-Path -LiteralPath $appIdentity))) {
    throw "Existing Rhythm shell registration prevents an isolated verification."
}

$temp = [System.IO.Path]::GetTempPath()
$root = Join-Path $temp ("gaojiezou-msi-smoke-" + [guid]::NewGuid().ToString("n"))
$install = Join-Path $root "program"
$data = Join-Path $root "data"
New-Item -Path $root -ItemType Directory | Out-Null
$installed = $false
$proc = $null
try {
    if ($ExistingCli) {
        & (Get-Item -LiteralPath $ExistingCli).FullName --create-empty --data-dir $data
        if ($LASTEXITCODE -ne 0) { throw "Previous Windows executable did not initialize smoke data." }
        $previousLibrary = Get-Content -LiteralPath (Join-Path $data "library.json") -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    $features = if ($CheckShell) { "Application,ShellIntegration" } else { "Application" }
    $installLog = Join-Path $root "install.log"
    $setup = Start-Process msiexec.exe -PassThru -Wait -WindowStyle Hidden -ArgumentList @(
        "/i", ('"{0}"' -f $msi), ('INSTALLDIR="{0}"' -f $install), "ADDLOCAL=$features",
        "/qn", "/norestart", "ARPSYSTEMCOMPONENT=1", "/L*V", ('"{0}"' -f $installLog)
    )
    if ($setup.ExitCode -notin @(0, 3010)) {
        Select-String -LiteralPath $installLog -Pattern "Error [0-9]+|Return value 3" | Select-Object -Last 10
        throw "MSI installation failed with exit code $($setup.ExitCode)."
    }
    $installed = $true
    if ($setup.ExitCode -ne 0) { throw "MSI unexpectedly requires a restart." }

    $cli = Join-Path $install "GaoJieZou-cli.exe"
    $gui = Join-Path $install "GaoJieZou.exe"
    $version = & $cli --version
    if ($LASTEXITCODE -ne 0 -or $version -notmatch '^\d+\.\d+\+\d+$') { throw "Installed CLI version invalid." }
    $marketingVersion, $buildNumber = $version -split '\+'
    $filename = "GaoJieZou-$version-Windows-x64.msi"
    $legacyFilename = "GaoJieZou-$marketingVersion-Windows-x64.msi"
    $leaf = Split-Path -Leaf $msi
    if ($leaf -ne $filename -and -not ([int]$buildNumber -le 3 -and $leaf -eq $legacyFilename)) {
        throw "MSI name and installed version disagree."
    }

    if ($CheckShell) {
        $command = (Get-Item -LiteralPath "$protocol\shell\open\command").GetValue("")
        if ($command -ne ('"{0}" "%1"' -f $gui)) { throw "MSI URI command differs from the installed program." }
        if ((Get-Item -LiteralPath $protocol).GetValueNames() -notcontains "URL Protocol") { throw "MSI URI protocol marker is missing." }
        foreach ($shortcut in @("GaoJieZou.lnk", "Rhythm Desktop Widgets.lnk")) {
            if (-not (Test-Path -LiteralPath (Join-Path $programMenu $shortcut))) { throw "MSI shortcut missing: $shortcut" }
        }
        $shell = New-Object -ComObject WScript.Shell
        $widgetLink = $shell.CreateShortcut((Join-Path $programMenu "Rhythm Desktop Widgets.lnk"))
        if ($widgetLink.TargetPath -ne $gui -or $widgetLink.Arguments -ne "--widgets") { throw "Widget shortcut is incorrect." }
        $identity = Get-Item -LiteralPath $appIdentity
        $registeredActivator = $identity.GetValue("CustomActivator")
        if ($identity.GetValue("RhythmExecutable") -ne $gui -or -not $registeredActivator) { throw "Toast identity registration is incomplete." }
        $explorer = New-Object -ComObject Shell.Application
        $rhythmLink = $explorer.NameSpace($programMenu).ParseName("GaoJieZou.lnk")
        if ($rhythmLink.ExtendedProperty("System.AppUserModel.ID") -ne $appModelID -or
            $rhythmLink.ExtendedProperty("System.AppUserModel.ToastActivatorCLSID") -ne $registeredActivator) {
            throw "Start menu notification shortcuts are missing their sender or activation identity."
        }
    }

    $socket = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $socket.Start()
    $port = $socket.LocalEndpoint.Port
    $socket.Stop()
    $url = "http://127.0.0.1:$port"
    $proc = Start-Process -FilePath $gui -ArgumentList @("--data-dir", ('"{0}"' -f $data), "--serve", "--no-browser",
        "--port", "$port") -PassThru -WindowStyle Hidden
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.UseProxy = $false
    $http = [Net.Http.HttpClient]::new($handler)
    $http.Timeout = [TimeSpan]::FromSeconds(3)
    try {
        $page = $null
        $deadline = (Get-Date).AddSeconds(75)
        do {
            if ($proc.HasExited) { throw "Installed GUI stopped early with code $($proc.ExitCode)." }
            try { $page = $http.GetStringAsync("$url/").GetAwaiter().GetResult() } catch { Start-Sleep -Milliseconds 750 }
        } while (-not $page -and (Get-Date) -lt $deadline)
        if (-not $page) { throw "The packaged interface did not start within 75 seconds." }
        $token = [regex]::Match($page, 'name="gao-token" content="([^"]+)"').Groups[1].Value
        if (-not $token) { throw "The packaged interface did not return a session token." }
        $http.DefaultRequestHeaders.Add("X-Gao-Token", $token)
        function Read-State {
            $http.GetStringAsync("$url/api/state").GetAwaiter().GetResult() | ConvertFrom-Json
        }
        function Invoke-ApiPost($route, $payload = "{}") {
            $content = [Net.Http.StringContent]::new($payload, [Text.Encoding]::UTF8, "application/json")
            try {
                $result = $http.PostAsync("$url$route", $content).GetAwaiter().GetResult()
                $result.EnsureSuccessStatusCode() | Out-Null
                $result.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json
            }
            finally { $content.Dispose() }
        }
        $initial = Read-State
        if ($ExistingCli) {
            if ($initial.status -ne "ready") { throw "Previously initialized Windows data did not open." }
            foreach ($habit in $previousLibrary.habits) {
                if ($initial.library.habits.id -notcontains $habit.id) { throw "An existing Windows habit was not retained." }
            }
        }
        else { Invoke-ApiPost "/api/library/create" | Out-Null }
        Invoke-ApiPost "/api/habits/save" '{"title":"MSI smoke habit","rewardCoins":4}' | Out-Null
        if ((Read-State).library.habits.title -notcontains "MSI smoke habit") { throw "Installed GUI did not read the saved habit." }
        $assets = @("/art/GaoJieZouIcon.png", "/art/EstateMeadowV352.png", "/art/AquariumPanoramaV352.png",
                    "/art/WorldMaterialsV357.png", "/art/FoliageV357.png", "/footprints-prefectures.json", "/gao-world.js")
        foreach ($asset in $assets) {
            $content = $http.GetByteArrayAsync("$url$asset").GetAwaiter().GetResult()
            if ($content.Count -lt 1000) { throw "Missing or incomplete bundled asset: $asset" }
        }
        Invoke-ApiPost "/api/shutdown" | Out-Null
        if (-not $proc.WaitForExit(20000) -or $proc.ExitCode -ne 0) { throw "Installed GUI failed to shut down cleanly." }
    }
    finally { $http.Dispose() }
    $reopened = & $cli --data-dir $data --inspect
    if ($LASTEXITCODE -ne 0 -or $reopened -notcontains "status=ready") { throw "The installed CLI could not reopen the data after shutdown." }
    Write-Output "Installed $version, loaded the bundled scene and map assets, wrote and read isolated Windows data, and stopped cleanly."
}
finally {
    if ($proc -and -not $proc.HasExited) { & taskkill.exe /PID $proc.Id /T /F | Out-Null }
    if ($installed) {
        $remove = Start-Process msiexec.exe -PassThru -Wait -WindowStyle Hidden -ArgumentList @("/x", $product, "/qn", "/norestart")
        if ($remove.ExitCode -ne 0) { throw "MSI uninstall failed with exit code $($remove.ExitCode)." }
        if (Test-Path -LiteralPath (Join-Path $install "GaoJieZou.exe")) { throw "Installed application remained after uninstall." }
        if ($CheckShell -and ((Test-Path -LiteralPath $programMenu) -or (Test-Path -LiteralPath $protocol) -or
                            (Test-Path -LiteralPath $appIdentity))) { throw "Shell registration remained after uninstall." }
        if (-not (Test-Path -LiteralPath (Join-Path $data "library.json"))) { throw "Uninstall removed the user data fixture." }
        Write-Output "Uninstall removed program files and preserved the data fixture."
    }
    if (Test-Path -LiteralPath $root) {
        $resolved = (Resolve-Path -LiteralPath $root).Path
        $parent = (Resolve-Path -LiteralPath $temp).Path
        if ((Split-Path -Parent $resolved).TrimEnd('\') -ne $parent.TrimEnd('\') -or
            (Split-Path -Leaf $resolved) -notmatch '^gaojiezou-msi-smoke-[0-9a-f]{32}$') {
            throw "Refused to clear an unexpected smoke directory."
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
