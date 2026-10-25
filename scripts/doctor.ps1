<#
.SYNOPSIS
    Checks that the tools needed to build and run Multi-AI are installed.
.DESCRIPTION
    Required tools (Flutter, Rust/Cargo, the MSVC compiler) fail the run with a
    remediation hint. Optional tools (Python for backend work, opencode and
    llama-server for the Code tab, coli for Colibri) only warn, since the app
    builds and runs without them.
    Exits 1 if any required check fails, 0 otherwise.
.EXAMPLE
    .\scripts\doctor.ps1
#>

$script:failures = 0

function Write-Result {
    param([string]$Status, [string]$Name, [string]$Detail, [string]$Hint)
    $color = @{ OK = 'Green'; WARN = 'Yellow'; FAIL = 'Red' }[$Status]
    Write-Host ("[{0,-4}] " -f $Status) -ForegroundColor $color -NoNewline
    Write-Host ("{0}  {1}" -f $Name, $Detail)
    if ($Hint -and $Status -ne 'OK') { Write-Host "       -> $Hint" }
    if ($Status -eq 'FAIL') { $script:failures++ }
}

function Test-Tool {
    param([string]$Name, [string]$Command, [bool]$Required, [string]$Hint, [string[]]$VersionArgs = @('--version'), [string[]]$ExtraDirs = @())
    $cmd = Get-Command $Command -ErrorAction SilentlyContinue
    if (-not $cmd) {
        foreach ($dir in $ExtraDirs) {
            $candidate = Join-Path $dir "$Command.exe"
            if (Test-Path $candidate) { $cmd = Get-Command $candidate; break }
        }
    }
    if ($cmd) {
        $version = ''
        try { $version = (& $cmd.Source @VersionArgs 2>$null | Select-Object -First 1) } catch {}
        Write-Result 'OK' $Name "$version".Trim() ''
    } else {
        Write-Result ($(if ($Required) { 'FAIL' } else { 'WARN' })) $Name 'not found' $Hint
    }
}

Write-Host "Required" -ForegroundColor Cyan
Test-Tool 'Flutter' 'flutter' $true 'https://docs.flutter.dev/get-started/install/windows'
# run-windows.ps1 prepends %USERPROFILE%\.cargo\bin itself, so accept it here too.
Test-Tool 'Rust (cargo)' 'cargo' $true 'winget install --id Rustlang.Rustup -e --source winget' @('--version') @((Join-Path $env:USERPROFILE '.cargo\bin'))

# cl.exe is rarely on PATH outside a Developer prompt; ask vswhere for the C++ toolset instead.
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vsPath = $null
if (Test-Path $vswhere) {
    $vsPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>$null | Select-Object -First 1
}
if ($vsPath) {
    Write-Result 'OK' 'MSVC C++ toolset' $vsPath ''
} else {
    Write-Result 'FAIL' 'MSVC C++ toolset' 'not found' 'Install Visual Studio Build Tools with the "Desktop development with C++" workload'
}

$embedPython = Join-Path $PSScriptRoot '..\backend\python\python.exe'
if (Test-Path $embedPython) {
    $v = & $embedPython --version 2>&1
    $status = if ("$v" -match '3\.14') { 'OK' } else { 'FAIL' }
    Write-Result $status 'Embedded Python' "$v" 'The .pyd ABI tag is cp314; the bundled interpreter must be CPython 3.14'
} else {
    # Only release builds bundle an interpreter; building the Flutter app doesn't need Python,
    # only working on or rebuilding the backend does.
    Test-Tool 'Python' 'python' $false 'Backend development only. Install CPython 3.14 (the compiled server .pyd is cp314)'
}

Write-Host ""
Write-Host "Optional" -ForegroundColor Cyan
# WinGet and npm install these without putting them on PATH, so look where they land too
# (the app does the same, and can install them itself from the Code tab).
$wingetLlama = @(Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Directory -Filter 'ggml.llamacpp*' -ErrorAction SilentlyContinue | ForEach-Object FullName)
Test-Tool 'opencode' 'opencode' $false 'Code tab only. Use the Install button in the Code tab, or: npm i -g opencode-ai' @('--version') @("$env:APPDATA\npm\node_modules\opencode-ai\bin", "$env:USERPROFILE\.opencode\bin")
Test-Tool 'llama-server' 'llama-server' $false 'Code tab only. Use the Install button in the Code tab, or: winget install ggml.llamacpp' @('--version') $wingetLlama
Test-Tool 'coli' 'coli' $false 'Colibri component only'

Write-Host ""
if ($script:failures -gt 0) {
    Write-Host "$($script:failures) required check(s) failed." -ForegroundColor Red
    exit 1
}
Write-Host "All required checks passed." -ForegroundColor Green
