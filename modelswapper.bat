@echo off
echo Starting replacement...
echo.

powershell -ExecutionPolicy Bypass -Command "Get-ChildItem -Path '%~dp0' -Recurse -File | ForEach-Object { try { $c = Get-Content $_.FullName -Raw; if ($c -like '*qwen2.5-coder:14b*') { $c -replace 'qwen2.5-coder:14b','qwen2.5-coder:14b' | Set-Content $_.FullName -Encoding UTF8; Write-Host ('Changed: ' + $_.FullName) } } catch { Write-Host ('Skipped: ' + $_.FullName) } }"

echo.
echo Finished!
pause


