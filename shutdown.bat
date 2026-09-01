@echo off
echo Stopping Jenkins on port 8080...
for /f "tokens=5" %%a in ('netstat -aon ^| find ":8080" ^| find "LISTENING"') do (
  taskkill /PID %%a /F
)
echo Done.
pause