# Windows-side build gate. Runs everything that does not need an Apple toolchain:
# the IPA patcher test suite and the release consistency check.
# The arm64 dylib itself can only be produced on macOS (build_dylib.sh) or GitHub Actions.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Push-Location $root
try {
    if (Get-Command py -ErrorAction SilentlyContinue) {
        $exe = 'py'; $args0 = @('-3')
    } elseif (Get-Command python -ErrorAction SilentlyContinue) {
        $exe = 'python'; $args0 = @()
    } else {
        throw 'Python 3.9+ not found (py launcher or python on PATH).'
    }

    Write-Host '[1/3] python version'
    & $exe @args0 -V

    Write-Host '[2/3] IPA patcher tests'
    & $exe @args0 -m unittest discover -s tests -p 'test_*.py'
    if ($LASTEXITCODE -ne 0) { throw 'Python test suite failed.' }

    Write-Host '[3/3] release consistency'
    & $exe @args0 tests/check_release.py
    if ($LASTEXITCODE -ne 0) { throw 'Release check failed.' }

    Write-Host ''
    Write-Host 'PORTABLE GATE PASSED. Native dylib still requires macOS/Xcode or the GitHub Actions workflow.'
}
finally {
    Pop-Location
}
