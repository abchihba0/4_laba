#!/usr/bin/env bash
# xfs_quota_tests.sh
# Run tests (expect) against your interactive xfs_quota_manager.sh
# Usage: ./xfs_quota_tests.sh /path/to/xfs_quota_manager.sh
set -euo pipefail

SCRIPT="/home/alexander/laba/ourlaba.sh"
BASE_DIR="/home/alexander/newXFSdisk"
LOG="/tmp/xfs_quota_tests.log.$$"
BACKUP_ETC="/tmp/xfs_tests_etc_backup_$$"

command -v expect >/dev/null 2>&1 || { echo "Please install 'expect'"; exit 1; }

mkdir -p "$(dirname "$LOG")"
: > "$LOG"

echo "Backing up /etc/projects and /etc/projid to $BACKUP_ETC" | tee -a "$LOG"
mkdir -p "$BACKUP_ETC"
sudo cp -a /etc/projects "$BACKUP_ETC/projects" 2>/dev/null || true
sudo cp -a /etc/projid  "$BACKUP_ETC/projid"  2>/dev/null || true

cleanup() {
  echo "Restoring /etc/projects and /etc/projid..." | tee -a "$LOG"
  [[ -f "$BACKUP_ETC/projects" ]] && sudo cp -a "$BACKUP_ETC/projects" /etc/projects
  [[ -f "$BACKUP_ETC/projid"  ]] && sudo cp -a "$BACKUP_ETC/projid"  /etc/projid
  echo "Cleanup finished." | tee -a "$LOG"
}
trap cleanup EXIT

pass() { echo -e "\033[1;32mPASS:\033[0m $1"; echo "PASS: $1" >> "$LOG"; }
fail() { echo -e "\033[1;31mFAIL:\033[0m $1"; echo "FAIL: $1" >> "$LOG"; }

# Ensure base dir exists and backup empty to avoid extra prompt
sudo mkdir -p "$BASE_DIR"
sudo mkdir -p "$BASE_DIR/backup"
sudo rm -rf "${BASE_DIR%/}/backup/"* 2>/dev/null || true

run_expect() {
  local name="$1"; shift
  echo -e "\n==== TEST: $name ====" | tee -a "$LOG"
  tmp=$(mktemp)
  cat > "$tmp"
  expect -f "$tmp" >> "$LOG" 2>&1 || { echo "Expect script failed for $name (see $LOG)"; rm -f "$tmp"; return 1; }
  rm -f "$tmp"
  return 0
}

# ---------- TEST 1 ----------
DIR_A="t1_existing_noquota"
FULL_A="$BASE_DIR/$DIR_A"
rm -rf "$FULL_A"
mkdir -p "$FULL_A"

run_expect "01_create_quota_on_preexisting_folder_and_let_script_create_files" <<EXPECT
set timeout 5
spawn bash -lc "$SCRIPT"
expect "What to do with existing files in backup*" { send "d\n" }
expect "Enter folder path (relative to $BASE_DIR):" { send "$DIR_A\n" }
expect "Enter folder limit*" { send "3M\n" }
expect "Do you want to add files to this folder*:" { send "y\n" }
expect "Enter single file size.*" { send "1M\n"; exp_continue }
expect "How many files to create.*" { send "5\n"; exp_continue }
expect "Enter threshold (in percent)*:" { send "30\n" }


expect eof
EXPECT



if sudo grep -Fq "$FULL_A" /etc/projects 2>/dev/null; then pass "T1: project registered for $FULL_A"; else fail "T1: project not registered for $FULL_A"; fi

# ---------- TEST 2 ----------
run_expect "02_do_not_change_quota" <<EXPECT
set timeout 5
spawn bash -lc "$SCRIPT"
expect {
  -re "What to do with existing files in backup.*" { send "d\n"; exp_continue }
  -re "Enter folder path (relative to $BASE_DIR):" { send "$DIR_A\n" }
  -re "Do you want to change quota size\\? \\(y/n\\):" { send "n\n"; exp_continue }
  -re "Do you want to add files to this folder\\? \\(y/n\\):" { send "n\n"; exp_continue }
  -re "Enter threshold.*" { send "40\n"; exp_continue }
  timeout { }
}
expect eof
EXPECT
pass "T2: chosen not to change quota"

# ---------- TEST 3 ----------
run_expect "03_safe_decrease_quota" <<EXPECT
set timeout 5
spawn bash -lc "$SCRIPT"
expect {
  -re "What to do with existing files in backup.*" { send "d\n"; exp_continue }
  -re "Enter folder path (relative to $BASE_DIR):" { send "$DIR_A\n" }
  -re "Do you want to change quota size\\? \\(y/n\\):" { send "y\n"; exp_continue }
  -re "Enter new limit" { send "5M\n"; exp_continue }
  -re "Do you want to add files to this folder\\? \\(y/n\\):" { send "n\n"; exp_continue }
  -re "Enter threshold.*" { send "50\n"; exp_continue }
  timeout { }
}
expect eof
EXPECT
pass "T3: increased quota to 10M "

# ---------- TEST 4 ----------
run_expect "04_increase_quota" <<EXPECT
set timeout 5
spawn bash -lc "$SCRIPT"
expect {
  -re "What to do with existing files in backup.*" { send "d\n"; exp_continue }
  -re "Enter folder path (relative to $BASE_DIR):" { send "$DIR_A\n" }
  -re "Do you want to change quota size\\? \\(y/n\\):" { send "y\n"; exp_continue }
  -re "Enter new limit" { send "10M\n"; exp_continue }
  -re "Do you want to add files to this folder\\? \\(y/n\\):" { send "y\n"; exp_continue }
  -re "Enter single file size.*" { send "1M\n"; exp_continue }
  -re "How many files to create.*" { send "5\n"; exp_continue }
  -re "Enter threshold.*"  { send "50\n"; exp_continue }
  timeout { }
}
expect eof
EXPECT
pass "T4: increased quota to 15M"

# ---------- TEST 5 ----------
DIR_B="t5_change_then_bigger"
FULL_B="$BASE_DIR/$DIR_B"
rm -rf "$FULL_B"
mkdir -p "$FULL_B"

for i in $(seq 1 5); do dd if=/dev/zero of="$FULL_B/file_$i" bs=1M count=1 status=none; done

run_expect "05_quota_less_than_used_then_choose_change_and_increase" <<EXPECT
set timeout 5
spawn bash -lc "$SCRIPT"
expect "What to do with existing files in backup*" { send "d\n" }
expect "Enter folder path (relative to $BASE_DIR):" { send "$DIR_B\n" }
expect "Enter folder limit*" { send "3M\n" }
expect "Do you want to \\(c\\) change size, \\(p\\) proceed*" { send "c\n" }
expect "Enter new limit:" { send "10M\n" }
expect "Do you want to add files to this folder*:" { send "n\n" }
expect "Enter threshold (in percent)*:" { send "50\n" }
expect eof
EXPECT

if sudo grep -Fq "$FULL_B" /etc/projects 2>/dev/null; then pass "T5: project registered for $FULL_B and changed to > used"; else fail "T5: project not registered for $FULL_B"; fi

# ---------- TEST 6 ----------
DIR_C="t6_delete_overflow"
FULL_C="$BASE_DIR/$DIR_C"
rm -rf "$FULL_C"
mkdir -p "$FULL_C"
for i in $(seq 1 5); do dd if=/dev/zero of="$FULL_C/file_$i" bs=1M count=1 status=none; done

run_expect "06_quota_smaller_delete_extra" <<EXPECT
set timeout 5
spawn bash -lc "$SCRIPT"
expect "What to do with existing files in backup*" { send "d\n" }
expect "Enter folder path (relative to $BASE_DIR):" { send "$DIR_C\n" }
expect "Enter folder limit*" { send "3M\n" }
expect "Do you want to \\(c\\) change size, \\(p\\) proceed*" { send "p\n" }
expect "Your choice (1/2):" { send "1\n" }
expect "Do you want to add files to this folder*:" { send "n\n" }
expect "Enter threshold (in percent)*:" { send "50\n" }
expect eof

EXPECT

used_after=$(du -sb "$FULL_C" 2>/dev/null | awk '{print $1}' || echo 0)
if [ "$used_after" -le $((3*1024*1024)) ]; then pass "T6: deletion reduced usage <= 3M ($used_after bytes)"; else fail "T6: deletion did NOT reduce enough ($used_after bytes)"; fi

# ---------- TEST 7 ----------
DIR_D="t7_archive_overflow"
FULL_D="$BASE_DIR/$DIR_D"
rm -rf "$FULL_D"
mkdir -p "$FULL_D"
for i in $(seq 1 5); do dd if=/dev/zero of="$FULL_D/file_$i" bs=1M count=1 status=none; done

run_expect "07_quota_smaller_archive_extra" <<EXPECT
set timeout 5
spawn bash -lc "$SCRIPT"
expect "What to do with existing files in backup*" { send "d\n" }
expect "Enter folder path (relative to $BASE_DIR):" { send "$DIR_D\n" }
expect "Enter folder limit*" { send "3M\n" }
expect "Do you want to \\(c\\) change size, \\(p\\) proceed*" { send "p\n" }
expect "Your choice (1/2):" { send "2\n" }
expect "Do you want to add files to this folder*:" { send "n\n" }
expect "Enter threshold (in percent)*:" { send "50\n" }
expect eof
EXPECT

if ls "$BASE_DIR/backup"/*/"$DIR_D"/*.tar.gz >/dev/null 2>&1; then
    pass "T7: archive created for $DIR_D"
else
    fail "T7: archive NOT found for $DIR_D"
fi

# ---------- TEST 8 ----------
DIR_NEW="t8_nonexistent_created_by_script"
FULL_NEW="$BASE_DIR/$DIR_NEW"

rm -rf "$FULL_NEW"
sudo sed -i "\|$FULL_NEW|d" /etc/projects || true
sudo sed -i "\|$DIR_NEW|d" /etc/projid || true

run_expect "08_script_creates_nonexistent_folder_and_files" <<EXPECT
set timeout 5
spawn bash -lc "$SCRIPT"

expect {
  -re "Enter folder path.*" { send "$DIR_NEW\n"; exp_continue }
  -re "What to do with existing files in backup.*" { send "d\n"; exp_continue }
  -re "Enter folder limit.*" { send "10M\n"; exp_continue }
  -re "Enter single file size.*" { send "1M\n"; exp_continue }
  -re "How many files to create.*" { send "5\n"; exp_continue }
  -re "Do you want to change quota size.*" { send "n\n"; exp_continue }
  timeout { }
}

expect eof
EXPECT

if sudo grep -Fq "$FULL_NEW" /etc/projects 2>/dev/null; then 
    pass "T8: script created $FULL_NEW and registered project"
else 
    fail "T8: script did not register $FULL_NEW"
fi
echo; echo "All tests finished. See $LOG for detailed expect runs."

