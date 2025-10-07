# === Pure PowerShell automated tester for disk_quota_manager.ps1 ===
# Fully automated; no expect.exe required.

$ErrorActionPreference = "Stop"

$SCRIPT = "C:\Users\kanuk\OneDrive\Desktop\script.ps1"
$BASE_DIR = "C:\Users\kanuk\newXFSdisk"
$LOG = "C:\Temp\disk_quota_tests.log"

# Создание папки для логов
New-Item -ItemType Directory -Force -Path (Split-Path $LOG) | Out-Null
Clear-Content -Path $LOG -ErrorAction SilentlyContinue

function Log($msg) {
    $msg | Tee-Object -Append -FilePath $LOG
}
function Pass($msg) { Write-Host "PASS: $msg" -ForegroundColor Green; Log "PASS: $msg" }
function Fail($msg) { Write-Host "FAIL: $msg" -ForegroundColor Red; Log "FAIL: $msg" }

function Run-Test($name, [string[]]$answers) {
    Write-Host "`n==== TEST: $name ====" -ForegroundColor Cyan
    Log "`n==== TEST: $name ===="

    $inputText = ($answers -join "`n") + "`n"
    $tempInput = New-TemporaryFile
    Set-Content -Path $tempInput -Value $inputText -Encoding UTF8

    try {
        # Используем Get-Content вместо '<'
        $output = Get-Content $tempInput | powershell -NoProfile -ExecutionPolicy Bypass -File $SCRIPT 2>&1
        $output | Tee-Object -Append -FilePath $LOG | Out-Null
        return $output
    }
    catch {
        Fail "Test '$name' crashed: $_"
        return @()
    }
    finally {
        Remove-Item $tempInput -Force -ErrorAction SilentlyContinue
    }
}


# --- Environment setup ---
New-Item -ItemType Directory -Force -Path $BASE_DIR | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $BASE_DIR "backup") | Out-Null
Remove-Item -Recurse -Force (Join-Path $BASE_DIR "backup\*") -ErrorAction SilentlyContinue

# --- TEST 1: Create new folder and files ---
$DIR_A = "t1_existing_noquota"
$FULL_A = Join-Path $BASE_DIR $DIR_A
Remove-Item -Recurse -Force $FULL_A -ErrorAction SilentlyContinue

Run-Test "T1_Create_Quota_and_Files" @(
    $DIR_A,      # Enter folder path
    "10M",       # Enter folder limit
    "1M",        # Enter single file size
    "5",         # How many files to create
    "60"         # Enter threshold
)
if (Test-Path $FULL_A) { Pass "T1: folder created successfully" } else { Fail "T1: folder not created" }

# --- TEST 2: Reuse existing folder, no change quota ---
Run-Test "T2_NoChangeQuota" @(
    $DIR_A,
    "10M",
    "40"   # threshold
)
Pass "T2 executed"

# --- TEST 3: Decrease quota below used size (forces archive/delete) ---
Run-Test "T3_DecreaseQuota" @(
    $DIR_A,
    "5M",
    "50"   # threshold
)
Pass "T3 executed"

# --- TEST 4: Increase quota again ---
Run-Test "T4_IncreaseQuota" @(
    $DIR_A,
    "10M",
    "1M",
    "5",
    "50"
)
Pass "T4 executed"

# --- TEST 5: Folder already exceeds limit; choose archive ---
$DIR_B = "t5_archive_case"
$FULL_B = Join-Path $BASE_DIR $DIR_B
Remove-Item -Recurse -Force $FULL_B -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $FULL_B | Out-Null
for ($i=1; $i -le 5; $i++) {
    fsutil file createnew (Join-Path $FULL_B "file_$i.bin") 1048576 | Out-Null
}
Run-Test "T5_ArchiveOverflow" @(
    $DIR_B,
    "3M",
    "a",   # Archive
    "50"   # threshold
)
# Проверяем, создался ли архив
$archiveExists = Get-ChildItem -Path (Join-Path $BASE_DIR "backup") -Recurse -Filter "*.zip" | Where-Object { $_.FullName -match $DIR_B }
if ($archiveExists) { Pass "T5: archive created" } else { Fail "T5: archive not found" }

# --- TEST 6: Delete overflow case ---
$DIR_C = "t6_delete_overflow"
$FULL_C = Join-Path $BASE_DIR $DIR_C
Remove-Item -Recurse -Force $FULL_C -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $FULL_C | Out-Null
for ($i=1; $i -le 5; $i++) {
    fsutil file createnew (Join-Path $FULL_C "file_$i.bin") 1048576 | Out-Null
}
Run-Test "T6_DeleteOverflow" @(
    $DIR_C,
    "3M",
    "d",   # Delete
    "50"   # threshold
)
$used = (Get-ChildItem -Recurse -File $FULL_C | Measure-Object -Property Length -Sum).Sum
if ($used -le 3MB) { Pass "T6: deletion reduced usage ≤3MB ($used bytes)" } else { Fail "T6: deletion did not reduce enough ($used bytes)" }

# --- TEST 7: Nonexistent folder created by script ---
$DIR_NEW = "t7_created_by_script"
$FULL_NEW = Join-Path $BASE_DIR $DIR_NEW
Remove-Item -Recurse -Force $FULL_NEW -ErrorAction SilentlyContinue
Run-Test "T7_Create_Nonexistent" @(
    $DIR_NEW,
    "10M",
    "1M",
    "5",
    "60"
)
if (Test-Path $FULL_NEW) { Pass "T7: script created folder $FULL_NEW" } else { Fail "T7: folder not created" }

Write-Host "`nAll tests finished. See log: $LOG" -ForegroundColor Yellow
