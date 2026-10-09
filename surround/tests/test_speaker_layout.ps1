# Builds isolated regression/probe executables; never overwrites bridge_control.exe.
[CmdletBinding()]
param([string]$ProbeEndpoint='')
$ErrorActionPreference='Stop'
$source=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\source\engine'))
$build=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'output\speaker-layout-build'))
$cmake='C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'
if(-not (Test-Path -LiteralPath $cmake)){throw 'Visual Studio CMake is required to compile this native mock test.'}
New-Item -ItemType Directory -Path $build -Force | Out-Null
$enginePath=$source.Replace('\','/')
$testPath=(Join-Path $PSScriptRoot 'test_speaker_layout.cpp').Replace('\','/')
$gameTestPath=(Join-Path $PSScriptRoot 'test_native_game_layout.cpp').Replace('\','/')
$definition=@"
cmake_minimum_required(VERSION 3.20)
project(speaker_layout_regression LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 17)
add_executable(speaker_layout_test "$testPath" "$enginePath/src/ComUtil.cpp" "$enginePath/src/DeviceEnum.cpp" "$enginePath/src/Guids.cpp" "$enginePath/test/WavFile.cpp")
target_link_libraries(speaker_layout_test PRIVATE ole32)
add_executable(speaker_layout_probe "$enginePath/src/BridgeControl.cpp" "$enginePath/src/ComUtil.cpp" "$enginePath/src/DeviceEnum.cpp" "$enginePath/src/Guids.cpp" "$enginePath/test/WavFile.cpp")
target_link_libraries(speaker_layout_probe PRIVATE ole32)
add_executable(native_game_layout_test "$gameTestPath" "$enginePath/src/ComUtil.cpp" "$enginePath/src/DeviceEnum.cpp" "$enginePath/src/Guids.cpp" "$enginePath/test/WavFile.cpp")
target_link_libraries(native_game_layout_test PRIVATE ole32 xaudio2 dsound)
"@
[IO.File]::WriteAllText((Join-Path $build 'CMakeLists.txt'),$definition)
& $cmake -S $build -B (Join-Path $build 'native') -G 'Visual Studio 17 2022' -A x64
if($LASTEXITCODE -ne 0){throw 'Mock test configuration failed.'}
& $cmake --build (Join-Path $build 'native') --config Release --target speaker_layout_test speaker_layout_probe native_game_layout_test
if($LASTEXITCODE -ne 0){throw 'Mock test compilation failed.'}
& (Join-Path $build 'native\Release\speaker_layout_test.exe')
if($LASTEXITCODE -ne 0){throw 'Speaker layout regression failed.'}
$controller=Join-Path $build 'native\Release\speaker_layout_probe.exe'
$help=& $controller --help
if($LASTEXITCODE -ne 0 -or $help -notmatch '--sessions ID'){throw 'Session command is missing from help.'}
# Reject malformed commands before attempting endpoint resolution or any policy operation.
try {
  $ErrorActionPreference='Continue' # Windows PowerShell represents expected native stderr as records.
  foreach($arguments in @(@('--sessions'), @('--sessions','not-an-id','extra'), @('--unknown','not-an-id'))) {
    & $controller @arguments 2>&1 | Out-Null
    if($LASTEXITCODE -ne 2){throw 'Invalid session command/arguments were not rejected.'}
  }
} finally { $ErrorActionPreference='Stop' }
Write-Output 'PASS: session command help and invalid-command guards.'
if($ProbeEndpoint) {
  & (Join-Path $build 'native\Release\speaker_layout_probe.exe') --speaker-info $ProbeEndpoint
  if($LASTEXITCODE -ne 0){throw 'Read-only speaker probe failed.'}
  & $controller --sessions $ProbeEndpoint
  if($LASTEXITCODE -ne 0){throw 'Read-only session snapshot failed or was partial.'}
  & (Join-Path $build 'native\Release\native_game_layout_test.exe') $ProbeEndpoint
  if($LASTEXITCODE -ne 0){throw 'Native gaming API layout probe failed; inspect reported XAudio2 and DirectSound results.'}
}
