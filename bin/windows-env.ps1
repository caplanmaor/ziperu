# Dot-source this before building on Windows with RubyInstaller:
#
#   . .\bin\windows-env.ps1
#   bundle exec rake compile test
#
# RubyInstaller is MinGW/UCRT, so the extension must be built for the GNU
# Rust target (`rustup target add x86_64-pc-windows-gnu` once), and bindgen
# needs clang's own resource headers (stdalign.h, mm_malloc.h), which it
# does not find on its own when libclang comes from the LLVM installer.

$ruby = "C:\Ruby34-x64"
$env:PATH = "$ruby\bin;$ruby\msys64\ucrt64\bin;$ruby\msys64\usr\bin;$env:PATH"

$env:RUST_TARGET = "x86_64-pc-windows-gnu"
$env:CARGO_BUILD_TARGET = "x86_64-pc-windows-gnu"

$clangInclude = Get-ChildItem "C:\Program Files\LLVM\lib\clang\*\include" -ErrorAction SilentlyContinue |
  Select-Object -First 1
if ($clangInclude) {
  # 8.3 short path: BINDGEN_EXTRA_CLANG_ARGS is whitespace-split, so no spaces.
  $fs = New-Object -ComObject Scripting.FileSystemObject
  $short = $fs.GetFolder($clangInclude.FullName).ShortPath -replace '\\', '/'
  $env:BINDGEN_EXTRA_CLANG_ARGS = "-I$short"
} else {
  Write-Warning "LLVM not found under C:\Program Files\LLVM; bindgen may fail to find stdalign.h"
}
