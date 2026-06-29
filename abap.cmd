@echo off
REM Windows launcher for the abap builder (pure Python stdlib, cross-platform).
REM Uses the Python launcher 'py' if present, else falls back to 'python'.
where py >nul 2>nul && (py "%~dp0tools\abap" %*) || (python "%~dp0tools\abap" %*)
