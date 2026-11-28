$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$root = Join-Path $env:RUNNER_TEMP ('rhythm-upgrade-' + [guid]::NewGuid().ToString('n'))
$program = Join-Path $root 'program'
$data = Join-Path $root 'data'
New-Item -Path $root -ItemType Directory | Out-Null
$old = (Get-Item -LiteralPath 'old/GaoJieZou-4.12+6-Windows-x64.msi').FullName
$new = (Get-Item -LiteralPath 'candidate/GaoJieZou-4.13+7-Windows-x64.msi').FullName
foreach ($package in @($old, $new)) {
    $sidecar = (Get-Content -LiteralPath "$package.sha256" -Raw).Trim() -split '\s+', 2
    $name = Split-Path -Leaf $package
    $actual = (Get-FileHash -LiteralPath $package -Algorithm SHA256).Hash
    if ($sidecar.Count -ne 2 -or $sidecar[0] -notmatch '^[a-f0-9]{64}$' -or
        $sidecar[1] -cne $name -or $actual -ne $sidecar[0]) {
        throw "MSI checksum mismatch for $name."
    }
    Write-Output "Verified $name SHA-256 $actual."
}

$installer = New-Object -ComObject WindowsInstaller.Installer
function ProductCode([string]$package) {
    $db = $installer.GetType().InvokeMember('OpenDatabase','InvokeMethod',$null,$installer,@($package,0))
    $q = [char]96
    $sql = "SELECT $q"+"Value$q"+" FROM $q"+"Property$q"+" WHERE $q"+"Property$q"+" = 'ProductCode'"
    $view = $db.GetType().InvokeMember('OpenView','InvokeMethod',$null,$db,@($sql))
    [void]$view.GetType().InvokeMember('Execute','InvokeMethod',$null,$view,@())
    $record = $view.GetType().InvokeMember('Fetch','InvokeMethod',$null,$view,@())
    $value = $record.GetType().InvokeMember('StringData','GetProperty',$null,$record,@(1))
    [void]$view.GetType().InvokeMember('Close','InvokeMethod',$null,$view,@())
    [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($db)
    return ([guid]$value).ToString('B').ToUpperInvariant()
}
function State([string]$code) {
    return $installer.GetType().InvokeMember('ProductState','GetProperty',$null,$installer,@($code))
}
function Install([string]$package, [string]$label) {
    $log = Join-Path $root "$label.log"
    $args = @('/i', ('"{0}"' -f $package), ('INSTALLDIR="{0}"' -f $program), 'ADDLOCAL=Application,ShellIntegration',
              '/qn','/norestart','/L*V', ('"{0}"' -f $log))
    $task = Start-Process msiexec.exe -Wait -PassThru -WindowStyle Hidden -ArgumentList $args
    if ($task.ExitCode -ne 0) {
        Select-String -LiteralPath $log -Pattern 'Error [0-9]+|Return value 3' | Select-Object -Last 10
        throw "MSI $label failed ($($task.ExitCode))."
    }
}
function Start-App {
    $socket = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
    $socket.Start()
    $port = $socket.LocalEndpoint.Port
    $socket.Stop()
    $url = "http://127.0.0.1:$port"
    $process = Start-Process -FilePath (Join-Path $program 'GaoJieZou.exe') -PassThru -WindowStyle Hidden -ArgumentList @(
        '--serve','--no-browser','--data-dir', ('"{0}"' -f $data),'--port',"$port")
    $deadline = (Get-Date).AddSeconds(60)
    try {
        do {
            if ($process.HasExited) { throw 'App exited before HTTP startup.' }
            try {
                $page = Invoke-WebRequest -NoProxy -Uri $url -TimeoutSec 2
                $token = [regex]::Match($page.Content, 'name="gao-token" content="([^"]+)"').Groups[1].Value
                if ($token) { return @{ Url=$url; Process=$process; Headers=@{'X-Gao-Token'=$token} } }
            } catch { Start-Sleep -Milliseconds 300 }
        } while ((Get-Date) -lt $deadline)
        throw 'App did not start.'
    } catch {
        if (!$process.HasExited) { Stop-Process -Id $process.Id }
        throw
    }
}
function Request($app, [string]$path, [string]$json) {
    if ($json) {
        return Invoke-RestMethod -NoProxy -Uri "$($app.Url)$path" -Headers $app.Headers -Method Post -ContentType 'application/json' -Body $json
    }
    return Invoke-RestMethod -NoProxy -Uri "$($app.Url)$path" -Headers $app.Headers
}
function Stop-App($app) {
    Request $app '/api/shutdown' '{}' | Out-Null
    if (!$app.Process.WaitForExit(20000) -or $app.Process.ExitCode -ne 0) { throw 'App did not exit cleanly.' }
}

$oldCode = ProductCode $old
$newCode = ProductCode $new
if ($oldCode -eq $newCode) { throw 'The upgrade packages unexpectedly share a product code.' }
if ((State $oldCode) -gt 0 -or (State $newCode) -gt 0) { throw 'Existing MSI registration prevents isolation.' }
$app = $null
try {
    Install $old 'install-build6'
    $cli = Join-Path $program 'GaoJieZou-cli.exe'
    if ((& $cli --version) -ne '4.12+6') { throw 'Wrong installed old version.' }
    & $cli --create-empty --data-dir $data
    if ($LASTEXITCODE -ne 0) { throw 'Could not create old-release fixture.' }
    $app = Start-App
    $habit = (Request $app '/api/habits/save' '{"title":"Synthetic habit from 4.12+6","rewardCoins":4}').result
    $water = (Request $app '/api/health/record' '{"kind":"water","amount":235,"note":"Synthetic hydration from 4.12+6"}').result
    $oldState = Request $app '/api/state'
    if ($oldState.version -ne '4.12+6' -or !$habit.id -or !$water.id -or
        ($oldState.library.habits | Where-Object id -eq $habit.id).title -ne $habit.title -or
        ($oldState.health.records | Where-Object id -eq $water.id).note -ne $water.note) {
        throw 'Old release did not persist the synthetic fixtures.'
    }
    Stop-App $app
    $app = $null

    Write-Output "Before upgrade: old MSI code $oldCode state $(State $oldCode); new MSI code $newCode state $(State $newCode)."
    Install $new 'upgrade-build7'
    Write-Output "After upgrade: old state $(State $oldCode); new state $(State $newCode); CLI version $(& $cli --version)."
    Select-String -LiteralPath (Join-Path $root 'upgrade-build7.log') -Pattern 'FindRelatedProducts|RemoveExistingProducts|ProductVersion|Property\((C|S)\): (OLDER_RHYTHM|NEWER_RHYTHM|ALLUSERS|MSIINSTALLPERUSER)|Product: .*uccessfully' | ForEach-Object { $_.Line }
    if ((State $oldCode) -gt 0 -or (State $newCode) -le 0) { throw 'MSI major upgrade did not replace the old product.' }
    if ((& $cli --version) -ne '4.13+7') { throw 'Wrong upgraded version.' }
    $app = Start-App
    $newState = Request $app '/api/state'
    if ($newState.version -ne '4.13+7') { throw 'Wrong running HTTP version after upgrade.' }
    $retained = $newState.library.habits | Where-Object id -eq $habit.id
    $retainedWater = $newState.health.records | Where-Object id -eq $water.id
    if ($retained.title -ne $habit.title -or $retained.rewardCoins -ne $habit.rewardCoins -or
        $retainedWater.note -ne $water.note -or $retainedWater.amount -ne $water.amount) {
        throw 'Upgrade changed the synthetic habit or health record.'
    }
    Stop-App $app
    $app = $null
    Write-Output "PASS: 4.12+6 MSI upgraded in place to 4.13+7, removed the old product registration, and reopened the same habit and health record."
} finally {
    if ($app -and !$app.Process.HasExited) { Stop-Process -Id $app.Process.Id }
    foreach ($product in @($newCode,$oldCode)) {
        if ((State $product) -gt 0) {
            $uninstall = Start-Process msiexec.exe -Wait -PassThru -WindowStyle Hidden -ArgumentList @('/x',$product,'/qn','/norestart')
            if ($uninstall.ExitCode -ne 0) { throw 'Upgrade fixture uninstall failed.' }
        }
    }
}
$libraryFile = Join-Path $data 'library.json'
$healthFile = Join-Path $data 'Integration/Modules/Health/health.sqlite'
if ((State $oldCode) -gt 0 -or (State $newCode) -gt 0 -or
    (Test-Path -LiteralPath (Join-Path $program 'GaoJieZou.exe')) -or
    !(Test-Path -LiteralPath $libraryFile) -or !(Test-Path -LiteralPath $healthFile)) {
    throw 'Uninstall did not remove the program and registrations and preserve the fixture files.'
}
$persistedHabit = (Get-Content -LiteralPath $libraryFile -Raw | ConvertFrom-Json).habits | Where-Object id -eq $habit.id
if ($persistedHabit.title -ne $habit.title) { throw 'Uninstall altered the synthetic habit.' }
Write-Output 'PASS: uninstall removed both registrations and preserved the synthetic data directory.'
