# === Windows PowerShell Disk Quota Manager ===
# Полная версия с исправлениями и работающей архивацией по проценту использования.

$BASE_DIR = "C:\Users\kanuk\newXFSdisk"
$BACKUP_DIR = Join-Path $BASE_DIR "backup"

# --- Utility Functions ---

function To-Bytes($s) {
    if (-not $s) { return 0 }
    if ($s -match '^(\d+)([KMG])$') {
        $num = [int]$matches[1]
        switch ($matches[2]) {
            'K' { return $num * 1KB }
            'M' { return $num * 1MB }
            'G' { return $num * 1GB }
        }
    } elseif ($s -match '^\d+$') {
        return [int]$s
    } else { return 0 }
}

function To-Human($b) {
    if ($b -ge 1GB) { "{0:N2}G" -f ($b/1GB) }
    elseif ($b -ge 1MB) { "{0:N2}M" -f ($b/1MB) }
    elseif ($b -ge 1KB) { "{0:N2}K" -f ($b/1KB) }
    else { "$b B" }
}

function Folder-SizeBytes($folder) {
    if (-not (Test-Path $folder)) { return 0 }
    Get-ChildItem -Path $folder -File | Measure-Object -Property Length -Sum | Select-Object -ExpandProperty Sum
}

function Files-SortedByCtime($folder) {
    Get-ChildItem -Path $folder -File | Sort-Object CreationTime
}

# --- Archive and delete logic ---

function Archive-Files($folder, $limitBytes, $moment) {
    $current = Folder-SizeBytes $folder
    Write-Host "DEBUG: archive_files called. current=$(To-Human $current), limit=$(To-Human $limitBytes)"
    if ($current -le $limitBytes) {
        Write-Host "archive_files: current size <= limit. Nothing to archive."
        return
    }

    $need = $current - $limitBytes
    Write-Host "archive_files: need to free $(To-Human $need)."

    $archiveDir = Join-Path $BACKUP_DIR (Join-Path $moment ([IO.Path]::GetFileName($folder)))
    New-Item -ItemType Directory -Path $archiveDir -Force | Out-Null

    $acc = 0
    $filesToArchive = @()
    foreach ($f in Files-SortedByCtime $folder) {
        $filesToArchive += $f
        $acc += $f.Length
        if ($acc -ge $need) { break }
    }

    if ($filesToArchive.Count -eq 0) {
        Write-Host "archive_files: nothing found to archive."
        return
    }

    $archiveName = Join-Path $archiveDir ("archive_" + (Get-Date -Format "yyyyMMddHHmmss") + ".zip")
    $paths = $filesToArchive | ForEach-Object { $_.FullName }

    Write-Host "archive_files: archiving $($filesToArchive.Count) files ($(To-Human $acc)) -> $archiveName"
    try {
        Compress-Archive -Path $paths -DestinationPath $archiveName -Force -ErrorAction Stop
    } catch {
        Write-Host "archive_files: Compress-Archive failed: $_"
        return
    }

    foreach ($p in $paths) {
        try { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue } catch { }
    }

    $newCurrent = Folder-SizeBytes $folder
    Write-Host "archive_files: done. New folder size: $(To-Human $newCurrent)"
}

function Delete-OldFiles-Minimal($folder, $limitBytes) {
    $current = Folder-SizeBytes $folder
    if ($current -le $limitBytes) { return }
    $need = $current - $limitBytes
    Write-Host "delete_old_files_minimal: need to free $(To-Human $need)."

    $acc = 0
    $delFiles = @()
    foreach ($f in Files-SortedByCtime $folder) {
        $delFiles += $f.FullName
        $acc += $f.Length
        if ($acc -ge $need) { break }
    }

    if ($delFiles.Count -eq 0) { return }
    foreach ($p in $delFiles) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue }
    Write-Host "delete_old_files_minimal: deleted $($delFiles.Count) files."
}

# --- Initialization ---

if (-not (Test-Path $BASE_DIR)) {
    Write-Host "Error: BASE_DIR $BASE_DIR not found."
    exit
}

if (-not (Test-Path $BACKUP_DIR)) {
    Write-Host "Creating backup dir: $BACKUP_DIR"
    New-Item -ItemType Directory -Path $BACKUP_DIR | Out-Null
}

# --- Folder input ---
$relpath = Read-Host "Enter folder path (relative to $BASE_DIR)"
$relpath = $relpath.TrimStart('\')
$folder = Join-Path $BASE_DIR $relpath
$created_now = $false
if (-not (Test-Path $folder)) {
    New-Item -ItemType Directory -Path $folder | Out-Null
    Write-Host "Folder created: $folder"
    $created_now = $true
} else {
    Write-Host "Folder exists: $folder"
}

# --- Limit input ---
while ($true) {
    $size_str = Read-Host "Enter folder limit (e.g. 100M, 1G)"
    $size_bytes = To-Bytes $size_str
    if ($size_bytes -gt 0) { break }
    Write-Host "Invalid input."
}

$current_size = Folder-SizeBytes $folder
if ($current_size -gt $size_bytes) {
    Write-Host "Folder already exceeds limit. Current $(To-Human $current_size), limit $(To-Human $size_bytes)"
    $action = Read-Host "Choose action: (d) Delete / (a) Archive"
    if ($action -match '^[dD]$') {
        Delete-OldFiles-Minimal $folder $size_bytes
    } else {
        Archive-Files $folder $size_bytes ("initial_limit_" + (Get-Date -Format "yyyyMMddHHmmss"))
    }
}

# --- File creation ---
if ($created_now) {
    while ($true) {
        $file_size_str = Read-Host "Enter single file size (e.g. 10M)"
        if ($file_size_str -notmatch '^\d+[KMG]$') { Write-Host "Invalid format"; continue }
        $k = Read-Host "How many files to create?"
        if (-not ($k -match '^\d+$') -or [int]$k -le 0) { Write-Host "Invalid number"; continue }
        $file_size_bytes = To-Bytes $file_size_str
        if ($file_size_bytes * [int]$k -gt $size_bytes) { Write-Host "Total exceeds folder limit"; continue }
        break
    }
    for ($i=1; $i -le $k; $i++) {
        $fname = Join-Path $folder ("file_" + (Get-Date -Format "yyyyMMddHHmmss") + "_$i.bin")
        $fs = [IO.File]::Create($fname)
        $fs.SetLength($file_size_bytes)
        $fs.Close()
    }
    Write-Host "File creation completed."
}

# --- Threshold control ---
while ($true) {
    $npercStr = Read-Host "Enter threshold (1-100) of folder usage relative to limit"
    if ($npercStr -match '^\d+$') {
        $nperc = [int]$npercStr
        if ($nperc -ge 1 -and $nperc -le 100) { break }
    }
    Write-Host "Enter number from 1 to 100."
}

$threshold = [math]::Floor($size_bytes * $nperc / 100)
$current_size = Folder-SizeBytes $folder

Write-Host "DEBUG: limit=$(To-Human $size_bytes), threshold=$nperc% ($(To-Human $threshold)), current=$(To-Human $current_size)"

if ($current_size -gt $threshold) {
    Write-Host "Current size $(To-Human $current_size) exceeds threshold $(To-Human $threshold). Archiving..."
    Archive-Files $folder $threshold ("percent_cleanup_" + (Get-Date -Format "yyyyMMddHHmmss"))
    $current_size = Folder-SizeBytes $folder
    Write-Host "After archiving: New folder size $(To-Human $current_size)"
} else {
    Write-Host "Current size $(To-Human $current_size) does not exceed threshold $(To-Human $threshold). No action needed."
}

Write-Host "Final folder size: $(To-Human (Folder-SizeBytes $folder))"
Write-Host "Done."
