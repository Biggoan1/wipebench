@echo off
rem WipeBench console - double-click to open. Runs as a standard user; the console asks for
rem elevation only for the actions that need it. From a stick, the Drivers tab points at
rem this stick's own Drivers\ folder.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0WipeBench-Console.ps1"
