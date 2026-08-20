$ErrorActionPreference = "Stop"
$workspaceRoot = Split-Path -Parent $PSScriptRoot
$toolsRoot = Join-Path $workspaceRoot ".android-tools"
$sdkRoot = Join-Path $toolsRoot "sdk"
$gradleHome = Join-Path $workspaceRoot ".gradle-home"
$outputRoot = Join-Path $workspaceRoot "output"

New-Item -ItemType Directory -Force -Path $toolsRoot, $sdkRoot, $gradleHome, $outputRoot | Out-Null

function Get-OrInstallJdk {
    $jdkContainer = Join-Path $toolsRoot "jdk"
    $java = Get-ChildItem -LiteralPath $jdkContainer -Filter java.exe -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -like "*\bin\java.exe" } |
        Select-Object -First 1
    if ($java) { return Split-Path -Parent (Split-Path -Parent $java.FullName) }

    $archive = Join-Path $toolsRoot "jdk17.zip"
    New-Item -ItemType Directory -Force -Path $jdkContainer | Out-Null
    Write-Host "Downloading JDK 17..."
    Invoke-WebRequest -Uri "https://api.adoptium.net/v3/binary/latest/17/ga/windows/x64/jdk/hotspot/normal/eclipse" -OutFile $archive
    Expand-Archive -LiteralPath $archive -DestinationPath $jdkContainer -Force
    $java = Get-ChildItem -LiteralPath $jdkContainer -Filter java.exe -Recurse |
        Where-Object { $_.FullName -like "*\bin\java.exe" } |
        Select-Object -First 1
    if (-not $java) { throw "JDK installation did not contain java.exe" }
    return Split-Path -Parent (Split-Path -Parent $java.FullName)
}

function Get-OrInstallSdkManager {
    $manager = Join-Path $sdkRoot "cmdline-tools\latest\bin\sdkmanager.bat"
    if (Test-Path -LiteralPath $manager) { return $manager }

    $archive = Join-Path $toolsRoot "android-commandline-tools.zip"
    $staging = Join-Path $toolsRoot "android-commandline-tools-unpacked"
    $latest = Join-Path $sdkRoot "cmdline-tools\latest"
    Write-Host "Downloading Android command-line tools..."
    Invoke-WebRequest -Uri "https://dl.google.com/android/repository/commandlinetools-win-11076708_latest.zip" -OutFile $archive
    New-Item -ItemType Directory -Force -Path $staging, $latest | Out-Null
    Expand-Archive -LiteralPath $archive -DestinationPath $staging -Force
    Copy-Item -Path (Join-Path $staging "cmdline-tools\*") -Destination $latest -Recurse -Force
    if (-not (Test-Path -LiteralPath $manager)) { throw "Android command-line tools installation failed" }
    return $manager
}

function Get-OrInstallGradle {
    $gradleRoot = Join-Path $toolsRoot "gradle"
    $gradle = Get-ChildItem -LiteralPath $gradleRoot -Filter gradle.bat -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -like "*\bin\gradle.bat" } |
        Select-Object -First 1
    if ($gradle) { return $gradle.FullName }

    $archive = Join-Path $toolsRoot "gradle-8.9-bin.zip"
    New-Item -ItemType Directory -Force -Path $gradleRoot | Out-Null
    Write-Host "Downloading Gradle 8.9..."
    Invoke-WebRequest -Uri "https://services.gradle.org/distributions/gradle-8.9-bin.zip" -OutFile $archive
    Expand-Archive -LiteralPath $archive -DestinationPath $gradleRoot -Force
    $gradle = Get-ChildItem -LiteralPath $gradleRoot -Filter gradle.bat -Recurse |
        Where-Object { $_.FullName -like "*\bin\gradle.bat" } |
        Select-Object -First 1
    if (-not $gradle) { throw "Gradle installation failed" }
    return $gradle.FullName
}

$env:JAVA_HOME = Get-OrInstallJdk
$env:ANDROID_HOME = $sdkRoot
$env:ANDROID_SDK_ROOT = $sdkRoot
$env:GRADLE_USER_HOME = $gradleHome
$sdkManager = Get-OrInstallSdkManager
$gradle = Get-OrInstallGradle

Write-Host "Accepting Android SDK licenses..."
1..30 | ForEach-Object { "y" } | & $sdkManager "--sdk_root=$sdkRoot" --licenses | Out-Host
Write-Host "Installing Android SDK 35..."
& $sdkManager "--sdk_root=$sdkRoot" "platform-tools" "platforms;android-35" "build-tools;35.0.0"
if ($LASTEXITCODE -ne 0) { throw "Android SDK package installation failed" }

$gradleArgs = @("--no-daemon", "--stacktrace", ":app:assembleRelease")

Push-Location $PSScriptRoot
try {
    & $gradle @gradleArgs
    if ($LASTEXITCODE -ne 0) { throw "Android build failed" }
} finally {
    Pop-Location
}

$sourceApk = Join-Path $PSScriptRoot "app\build\outputs\apk\release\app-release.apk"
$targetApk = Join-Path $outputRoot "gotolibrary-native-v1.4.2.apk"
if (-not (Test-Path -LiteralPath $sourceApk)) { throw "APK output was not found" }
Copy-Item -LiteralPath $sourceApk -Destination $targetApk -Force
Write-Host "APK ready: $targetApk"
