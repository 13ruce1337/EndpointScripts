@echo off
setlocal EnableExtensions
rem Offline Windows repair for WinPE/WinRE. No install/restore media required.
rem Run from X: (the RAM disk). Does not use findstr.exe or choice.exe.
rem
rem Flow:
rem   0. Preflight: locate Windows and the EFI System Partition (FAT32, System)
rem   1. CHKDSK /f        (logged, checked for bad sectors)
rem   2. DISM offline     (optional revert of pending updates, then RestoreHealth
rem                        from the local component store only)
rem   3. SFC offline
rem   4. If bad sectors, CHKDSK exit >= 3, or SFC failed: CHKDSK /r + SFC again
rem   5. BCDBOOT          (retry after ESP chkdsk, optional ESP reformat)
rem   6. Drive report     (shown and saved to %WIN%\RepairLogs)
rem
rem Unlock BitLocker first if needed:
rem   manage-bde -unlock C: -RecoveryPassword YOUR-48-DIGIT-KEY

rem ----------------------------- Settings -------------------------------
set "WIN=C:"
rem Optional: EFI letter (e.g. S:) to skip auto-detection.
set "EFI_OVERRIDE="

rem ------------------------------ State ---------------------------------
for %%V in (EFI NEED_FULL FULL_REASON BADSECT SFC2_RC BCD_RC OFF_BUILD OFF_EDITION OFF_DISPVER PE_BUILD _FW) do set "%%V="
set "CHK_RC=0"
set "SFC_RC=0"
set "DISM_RC=skipped"
set "REVERT_RC=not run"
set "CHKLOG=%TEMP%\chkdsk.log"
set "DP=%TEMP%\dp.txt"
set "NTCV=Microsoft\Windows NT\CurrentVersion"

rem ---------------------------- Preflight -------------------------------
if not exist "%WIN%\Windows\System32\config\SYSTEM" (
  for %%L in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do (
    if not defined _FW if exist "%%L:\Windows\System32\config\SYSTEM" set "_FW=%%L:"
  )
)
if defined _FW (
  echo NOTE: Windows not found at %WIN%. Using %_FW% instead.
  set "WIN=%_FW%"
)
if not exist "%WIN%\Windows\System32\config\SYSTEM" (
  echo ERROR: Windows installation not found on any drive letter.
  echo If BitLocker is enabled, unlock the drive first, then try again.
  pause
  exit /b 2
)

rem Offline build/edition. If the hive will not load, DISM would fail with
rem error 50 ("Vista RTM or earlier"), so DISM is skipped in that case.
reg unload HKLM\OFFSOFT >nul 2>&1
reg load HKLM\OFFSOFT "%WIN%\Windows\System32\config\SOFTWARE" >nul 2>&1
if not errorlevel 1 (
  call :RegVal "HKLM\OFFSOFT\%NTCV%" CurrentBuild OFF_BUILD
  call :RegVal "HKLM\OFFSOFT\%NTCV%" DisplayVersion OFF_DISPVER
  call :RegVal "HKLM\OFFSOFT\%NTCV%" EditionID OFF_EDITION
  reg unload HKLM\OFFSOFT >nul 2>&1
)
call :RegVal "HKLM\SOFTWARE\%NTCV%" CurrentBuild PE_BUILD
set /a "_PEB=PE_BUILD+0, _OFFB=OFF_BUILD+0" 2>nul

if defined EFI_OVERRIDE (set "EFI=%EFI_OVERRIDE%") else call :FindEfi
if not defined EFI (
  echo ERROR: Could not find a FAT32 System volume ^(EFI partition^).
  echo This may be a legacy BIOS/MBR install. Set EFI_OVERRIDE to map it manually.
  pause
  exit /b 3
)

echo.
echo ================ Preflight ================
echo   Windows volume:  %WIN%
echo   EFI volume:      %EFI%
if defined OFF_BUILD (
  echo   Offline build:   %OFF_BUILD% %OFF_DISPVER% %OFF_EDITION%
) else (
  echo   Offline build:   UNREADABLE - SOFTWARE hive could not be loaded, DISM will be skipped
)
echo   WinPE build:     %PE_BUILD% ^(%PROCESSOR_ARCHITECTURE%^)
if exist "%WIN%\Windows\WinSxS\pending.xml" echo   Pending updates: YES ^(you will be asked whether to revert them^)
echo ===========================================
if /i "%PROCESSOR_ARCHITECTURE%"=="x86" if exist "%WIN%\Windows\SysWOW64" echo WARNING: x86 WinPE cannot service 64-bit Windows. Boot an amd64 WinPE.
if %_PEB% GTR 0 if %_PEB% LSS %_OFFB% echo WARNING: WinPE build is older than the offline build. DISM/BCDBOOT may fail.
echo.
echo If CHKDSK finds bad sectors or SFC fails, a full CHKDSK /r surface scan
echo and a second SFC pass will run automatically. CHKDSK /r can take hours.
echo.
echo Verify these letters before continuing.
pause

rem ----------------------------------------------------------------------
rem [1/5] CHKDSK /f - output captured so bad sectors can be detected.
rem /x forces a dismount so no hidden Y/N prompt can hang the script.
rem ----------------------------------------------------------------------
echo [1/5] CHKDSK /f...
echo   Output is logged and shown when finished. There is no live progress.
chkdsk %WIN% /f /x > "%CHKLOG%" 2>&1
set "CHK_RC=%errorlevel%"
type "%CHKLOG%"
echo   CHKDSK exit code: %CHK_RC%

rem Look for "   1234 KB in bad sectors." (English output only).
for /f "usebackq tokens=1-5" %%a in ("%CHKLOG%") do (
  if /i "%%c %%d %%e"=="in bad sectors." if not "%%a"=="0" set "BADSECT=%%a %%b"
)
if defined BADSECT (
  echo WARNING: CHKDSK reports %BADSECT% in bad sectors.
  call :NeedFull "bad sectors reported by CHKDSK"
)
if %CHK_RC% GEQ 3 (
  echo WARNING: CHKDSK could not check the volume or could not fix all errors.
  call :NeedFull "CHKDSK exit code %CHK_RC%"
)

rem ----------------------------------------------------------------------
rem [2/5] DISM, offline, using only what is already on the disk.
rem Scratch dir is on the target disk; WinPE's default 32 MB is too small.
rem ----------------------------------------------------------------------
echo [2/5] DISM ^(offline, no source media^)...
if not defined OFF_BUILD (
  echo   Skipped: offline registry is unreadable. Check WIN or registry damage.
  goto :Sfc
)
set "SCR=%WIN%\DismScratch"
if not exist "%SCR%" mkdir "%SCR%" >nul 2>&1

set "ANS=N"
if exist "%WIN%\Windows\WinSxS\pending.xml" (
  echo   Pending update actions found. A failed update can cause boot loops and
  echo   makes SFC refuse to run with "a system repair pending".
  set /p "ANS=  Revert pending update actions? [Y/N] "
)
if /i not "%ANS%"=="Y" goto :DismRestore
dism /Image:%WIN%\ /ScratchDir:%SCR% /Cleanup-Image /RevertPendingActions
set "REVERT_RC=%errorlevel%"

:DismRestore
rem /LimitAccess: no Windows Update. Repairs only from the local component store.
dism /Image:%WIN%\ /ScratchDir:%SCR% /Cleanup-Image /RestoreHealth /LimitAccess
set "DISM_RC=%errorlevel%"
rd /s /q "%SCR%" >nul 2>&1
if not "%DISM_RC%"=="0" (
  echo WARNING: DISM RestoreHealth returned %DISM_RC%. If this is 0x800f081f, the
  echo          repair needs files that are not on this disk. SFC will still try.
)

:Sfc
rem ----------------------------------------------------------------------
rem [3/5] Offline SFC
rem ----------------------------------------------------------------------
echo [3/5] Offline SFC...
call :RunSfc SFC_RC
if not "%SFC_RC%"=="0" (
  echo WARNING: SFC returned a nonzero status ^(%SFC_RC%^).
  call :NeedFull "SFC failure"
)

rem ----------------------------------------------------------------------
rem [4/5] Full repair: CHKDSK /r surface scan, then SFC again
rem ----------------------------------------------------------------------
if not defined NEED_FULL (
  echo [4/5] Full repair not needed. Skipping.
  goto :Bcd
)
echo [4/5] Full repair triggered: %FULL_REASON%
echo   Running CHKDSK /r ^(full surface scan^). This can take a long time.
chkdsk %WIN% /r /x
if errorlevel 3 echo WARNING: CHKDSK /r could not fix all errors. The disk may be failing.
echo   Re-running offline SFC...
call :RunSfc SFC2_RC
if not "%SFC2_RC%"=="0" echo WARNING: SFC still returned %SFC2_RC%. Some files may be beyond local repair.

:Bcd
rem ----------------------------------------------------------------------
rem [5/5] BCDBOOT (retry after ESP chkdsk, then optionally after reformat)
rem ----------------------------------------------------------------------
echo [5/5] BCDBOOT...
if not exist "%EFI%\EFI" echo   NOTE: %EFI% has no \EFI folder yet. BCDBOOT will create it.
if not exist "%WIN%\Windows\Boot\EFI\bootmgfw.efi" echo WARNING: %WIN%\Windows\Boot\EFI\bootmgfw.efi is missing. BCDBOOT has nothing to copy.
for /f "tokens=3-5" %%a in ('dir /a "%EFI%\" 2^>nul') do (
  if /i "%%b %%c"=="bytes free" echo   ESP free space: %%a bytes
)

call :RunBcd && goto :Finish
echo WARNING: BCDBOOT failed ^(%BCD_RC%^). Checking the ESP filesystem and retrying...
chkdsk %EFI% /f /x
call :RunBcd && goto :Finish

echo.
echo BCDBOOT still fails. The ESP may be full or its FAT32 filesystem damaged.
echo Reformatting erases EVERYTHING on the ESP ^(other boot loaders, vendor tools^).
set "ANS="
set /p "ANS=Reformat %EFI% as FAT32 and retry BCDBOOT? [Y/N] "
if /i not "%ANS%"=="Y" goto :Finish
call :DpWrite "select volume %EFI:~0,1%" "format fs=fat32 quick label=SYSTEM"
diskpart /s "%DP%"
call :RunBcd || echo WARNING: BCDBOOT failed even on a freshly formatted ESP.

:Finish
rem Save logs off the X: RAM disk so they survive a reboot.
set "LOGDIR=%WIN%\RepairLogs"
if not exist "%LOGDIR%\" mkdir "%LOGDIR%" >nul 2>&1
if not exist "%LOGDIR%\" set "LOGDIR=%TEMP%"
copy /y "%CHKLOG%" "%LOGDIR%\" >nul 2>&1
for %%F in ("X:\Windows\Logs\DISM\dism.log" "X:\Windows\Logs\CBS\CBS.log") do (
  if exist %%F copy /y %%F "%LOGDIR%\" >nul 2>&1
)
call :Report > "%LOGDIR%\drive_report.txt" 2>&1
type "%LOGDIR%\drive_report.txt"
del /q "%DP%" >nul 2>&1

echo.
echo Logs and this report were saved to %LOGDIR%
if /i "%LOGDIR%"=="%TEMP%" echo NOTE: %LOGDIR% is the RAM disk. Copy the files off before rebooting.
if defined BADSECT echo Bad sectors were found. Back up data and plan to replace the disk.
pause
endlocal
exit /b 0


rem ============================ Helpers =================================

rem :Report - repair results plus a CLI drive health report.
:Report
echo ================== Repair results ==================
echo   Windows volume:      %WIN%  %OFF_BUILD% %OFF_DISPVER% %OFF_EDITION%
echo   EFI volume:          %EFI%
echo   CHKDSK /f exit code: %CHK_RC%
if defined BADSECT (echo   Bad sectors:         %BADSECT%) else echo   Bad sectors:         none reported
echo   DISM revert pending: %REVERT_RC%
echo   DISM RestoreHealth:  %DISM_RC%
echo   SFC exit code:       %SFC_RC%
if defined NEED_FULL (echo   Full repair:         ran - %FULL_REASON%, SFC 2nd pass %SFC2_RC%) else echo   Full repair:         not needed
echo   BCDBOOT exit code:   %BCD_RC%
echo.
echo ==================== Drive report ====================
call :DpWrite "list disk" "select volume %WIN:~0,1%" "detail disk"
diskpart /s "%DP%"
echo.
echo --- Volume %WIN% ---
fsutil volume diskfree %WIN%
fsutil dirty query %WIN%
echo.
echo --- Physical disks / SMART ---
set "WMIC=%SystemRoot%\System32\wbem\wmic.exe"
if not exist "%WMIC%" (
  echo   wmic is not available in this WinPE. Add WinPE-WMI to the image for SMART data.
  exit /b 0
)
rem for /f converts wmic's Unicode output to plain text so the report file stays readable.
for /f "delims=" %%l in ('"%WMIC%" diskdrive get Model^,SerialNumber^,Size^,InterfaceType^,Status 2^>nul') do echo %%l
for /f "delims=" %%l in ('"%WMIC%" /namespace:\\root\wmi path MSStorageDriver_FailurePredictStatus get InstanceName^,PredictFailure 2^>nul') do echo %%l
echo   PredictFailure TRUE means the drive's SMART data predicts failure.
exit /b 0

rem :NeedFull "reason" - flag the full repair pass; keeps the first reason.
:NeedFull
set "NEED_FULL=1"
if not defined FULL_REASON set "FULL_REASON=%~1"
exit /b 0

rem :RunSfc outvar - offline SFC, stores the exit code in outvar.
:RunSfc
sfc /scannow /offbootdir=%WIN%\ /offwindir=%WIN%\Windows
set "%~1=%errorlevel%"
exit /b 0

rem :RunBcd - BCDBOOT to the ESP, sets BCD_RC and returns its exit code.
:RunBcd
bcdboot %WIN%\Windows /s %EFI% /f UEFI /v
set "BCD_RC=%errorlevel%"
exit /b %BCD_RC%

rem :RegVal key value outvar - reads a registry value into outvar.
:RegVal
set "%~3="
for /f "tokens=1,2,*" %%a in ('reg query "%~1" /v %~2 2^>nul') do (
  if /i "%%a"=="%~2" set "%~3=%%c"
)
exit /b 0

rem :DpWrite "line" ["line" ...] - writes a diskpart script to %DP%.
:DpWrite
type nul > "%DP%"
for %%s in (%*) do >> "%DP%" echo %%~s
exit /b 0

rem :FindEfi - first volume that is FAT32 and marked System in "list volume".
rem Uses its letter if it has one, otherwise assigns a free letter. Sets EFI.
:FindEfi
set "_EV="
set "_EL="
echo Detecting EFI System Partition ^(FAT32, System^)...
call :DpWrite "list volume"
for /f "delims=" %%l in ('diskpart /s "%DP%"') do call :EfiLine "%%l"
if not defined _EV exit /b 0
if defined _EL if "%_EL:~1%"=="" if exist "%_EL%:\" (
  set "EFI=%_EL%:"
  exit /b 0
)
for %%L in (S T U V W Y Z) do if not defined EFI if not exist "%%L:\" (
  call :DpWrite "select volume %_EV%" "assign letter=%%L"
  diskpart /s "%DP%" >nul
  if exist "%%L:\" set "EFI=%%L:"
)
exit /b 0

rem :EfiLine "line" - parses one "list volume" row. "*" is a delimiter so the
rem selected row parses like the others. Token 3 is the letter if one is
rem assigned; otherwise it is the label or "FAT32" (more than one character).
:EfiLine
if defined _EV exit /b 0
set "_L=%~1"
if "%_L:FAT32=%"=="%_L%" exit /b 0
if "%_L:System=%"=="%_L%" exit /b 0
for /f "tokens=1-3 delims=* " %%a in ("%_L%") do (
  if /i "%%a"=="Volume" set "_EV=%%b" & set "_EL=%%c"
)
exit /b 0
