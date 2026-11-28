$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$root = Join-Path $env:RUNNER_TEMP ('rhythm-upgrade-' + [guid]::NewGuid().ToString('n'))
$program = Join-Path $root 'program'
$data = Join-Path $root 'data'
New-Item -Path $root -ItemType Directory | Out-Null
$old = Join-Path $root 'GaoJieZou-4.12+5-Windows-x64.msi'
$new = (Get-Item -LiteralPath 'candidate/GaoJieZou-4.12+6-Windows-x64.msi').FullName
$uri = 'https://github.com/UCASerYff/GaoJieZou/releases/download/windows-v4.12-build.5/GaoJieZou-4.12%2B5-Windows-x64.msi'
Invoke-WebRequest -Uri $uri -OutFile $old
if ((Get-FileHash -LiteralPath $old -Algorithm SHA256).Hash -ne '299affe3a4e62923d2da69dff0ead19c2aa0d88e9b70b6f31058d9c0094d5ddd') { throw 'Old MSI checksum mismatch.' }
$expected = ((Get-Content -LiteralPath "$new.sha256" -Raw).Trim() -split '\s+')[0]
if ((Get-FileHash -LiteralPath $new -Algorithm SHA256).Hash -ne $expected) { throw 'Candidate MSI checksum mismatch.' }

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
if ((State $oldCode) -gt 0 -or (State $newCode) -gt 0) { throw 'Existing MSI registration prevents isolation.' }
$app = $null
try {
    Install $old 'install-build5'
    $cli = Join-Path $program 'GaoJieZou-cli.exe'
    if ((& $cli --version) -ne '4.12+5') { throw 'Wrong installed old version.' }
    & $cli --create-empty --data-dir $data
    if ($LASTEXITCODE -ne 0) { throw 'Could not create old-release fixture.' }
    $app = Start-App
    Request $app '/api/habits/save' '{"title":"Synthetic habit from build 5","rewardCoins":4}' | Out-Null
    $habit = (Request $app '/api/state').library.habits | Where-Object title -eq 'Synthetic habit from build 5'
    if (!$habit.id) { throw 'Old release did not persist the fixture.' }
    Stop-App $app
    $app = $null

    Write-Output "Before upgrade: old MSI code $oldCode state $(State $oldCode); new MSI code $newCode state $(State $newCode)."
    Install $new 'upgrade-build6'
    Write-Output "After upgrade: old state $(State $oldCode); new state $(State $newCode); CLI version $(& $cli --version)."
    Select-String -LiteralPath (Join-Path $root 'upgrade-build6.log') -Pattern 'FindRelatedProducts|RemoveExistingProducts|ProductVersion|Property\((C|S)\): (OLDER_RHYTHM|NEWER_RHYTHM|ALLUSERS|MSIINSTALLPERUSER)|Product: .*uccessfully' | ForEach-Object { $_.Line }
    if ((State $oldCode) -gt 0 -or (State $newCode) -le 0) { throw 'MSI major upgrade did not replace the old product.' }
    if ((& $cli --version) -ne '4.12+6') { throw 'Wrong upgraded version.' }
    $app = Start-App
    $retained = (Request $app '/api/state').library.habits | Where-Object id -eq $habit.id
    if ($retained.title -ne $habit.title -or $retained.rewardCoins -ne $habit.rewardCoins) { throw 'Upgrade changed fixture data.' }
    Stop-App $app
    $app = $null
    Write-Output "PASS: build 5 MSI upgraded in place to build 6, removed its old product registration, and reopened the same saved habit."
} finally {
    if ($app -and !$app.Process.HasExited) { Stop-Process -Id $app.Process.Id }
    foreach ($product in @($newCode,$oldCode)) {
        if ((State $product) -gt 0) {
            $uninstall = Start-Process msiexec.exe -Wait -PassThru -WindowStyle Hidden -ArgumentList @('/x',$product,'/qn','/norestart')
            if ($uninstall.ExitCode -ne 0) { throw 'Upgrade fixture uninstall failed.' }
        }
    }
}
if ((Test-Path -LiteralPath (Join-Path $program 'GaoJieZou.exe')) -or !(Test-Path -LiteralPath (Join-Path $data 'library.json'))) {
    throw 'Uninstall did not remove the program and preserve the fixture.'
}
Write-Output 'PASS: uninstall preserved the synthetic data directory.'
