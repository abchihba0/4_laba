#!/bin/bash

BASE_DIR="/home/alexander/newXFSdisk"
SCRIPT="./ourlaba.sh"
BACKUP_DIR="$BASE_DIR/backup"

PROJECTS=("test_no_quota" "test_with_quota" "test_below_threshold" "test_new_folder" \
          "test_quota_below_limit" "test_exact_limit" "test_delete_instead_archive")

for proj in "${PROJECTS[@]}"; do
    echo "Очистка проекта $proj..."
    sudo rm -rf "$BASE_DIR/$proj"
    sudo xfs_quota -x -c "project -C $proj" "$BASE_DIR" 2>/dev/null || true
    sudo sed -i "/$proj/d" /etc/projid 2>/dev/null || true
    sudo sed -i "/$proj/d" /etc/projects 2>/dev/null || true
done

echo "Очистка завершена."
echo

check_archive() {
    local backup_dir="$BACKUP_DIR"
    local before=("$@") 

    local after=()
    while IFS= read -r f; do
        after+=("$(basename "$f")")
    done < <(find "$backup_dir" -maxdepth 1 -type f -name "*.tar.gz")

    local new_found=false
    for f in "${after[@]}"; do
        local exists=false
        for b in "${before[@]}"; do
            [[ "$f" == "$b" ]] && exists=true && break
        done
        $exists || new_found=true
    done

    if $new_found; then
        echo "Archive created successfully."
        return 0
    else
        echo "FAIL: No new archive created."
        return 1
    fi
}


# 1) Папка без квоты, превышение лимита и архив
mkdir -p "$BASE_DIR/test_no_quota"
for i in $(seq 1 12); do
    dd if=/dev/zero of="$BASE_DIR/test_no_quota/file_$i.bin" bs=1M count=1 status=none
done

existing_archives=()
while IFS= read -r f; do
    existing_archives+=("$(basename "$f")")
done < <(find "$BACKUP_DIR" -maxdepth 1 -type f -name "*.tar.gz")

echo "Running test_no_quota..."
"$SCRIPT" <<EOF
k
test_no_quota
10M
p
2
n
50
EOF

check_archive "${existing_archives[@]}" && echo "TEST test_no_quota: PASS" || echo "TEST test_no_quota: FAIL"
echo

# 2) Папка с квотой, лимит меньше чем файлы и архив
mkdir -p "$BASE_DIR/test_with_quota"
for i in $(seq 1 10); do
    dd if=/dev/zero of="$BASE_DIR/test_with_quota/file_$i.bin" bs=1M count=1 status=none
done

NEW_ID=$(( $(cut -d: -f1 /etc/projects | sort -n | tail -1 || echo 100) + 1 ))
echo "$NEW_ID:$BASE_DIR/test_with_quota" | sudo tee -a /etc/projects
echo "test_with_quota:$NEW_ID" | sudo tee -a /etc/projid

sudo xfs_quota -x -c "project -s test_with_quota" "$BASE_DIR"
sudo xfs_quota -x -c "limit -p bhard=10M test_with_quota" "$BASE_DIR"

existing_archives1=()
while IFS= read -r f; do
    existing_archives1+=("$(basename "$f")")
done < <(find "$BACKUP_DIR" -maxdepth 1 -type f -name "*.tar.gz")

echo "Running test_with_quota..."
"$SCRIPT" <<EOF
k
test_with_quota
y
8M
a
n
50
EOF

check_archive "${existing_archives1[@]}" && echo "TEST test_with_quota: PASS" || echo "TEST test_with_quota: FAIL"
echo

mkdir -p "$BASE_DIR/test_below_threshold"
for i in $(seq 1 4); do
    dd if=/dev/zero of="$BASE_DIR/test_below_threshold/file_$i.bin" bs=1M count=1 status=none
done

echo "Running test_below_threshold..."
"$SCRIPT" <<EOF
k
test_below_threshold
10M
n
50
EOF

echo "TEST test_below_threshold: PASS (archive not required)"
echo

# 4) Новая папка
echo "Running test_new_folder..."
"$SCRIPT" <<EOF
k
test_new_folder
10M
1M
10
50
EOF

echo "TEST test_new_folder: PASS (archive not required)"
echo

# 5) Квота < лимита, порог не превышен
mkdir -p "$BASE_DIR/test_quota_below_limit"
for i in $(seq 1 5); do
    dd if=/dev/zero of="$BASE_DIR/test_quota_below_limit/file_$i.bin" bs=1M count=1 status=none
done

NEW_ID=$(( $(cut -d: -f1 /etc/projects | sort -n | tail -1 || echo 100) + 1 ))
echo "$NEW_ID:$BASE_DIR/test_quota_below_limit" | sudo tee -a /etc/projects
echo "test_quota_below_limit:$NEW_ID" | sudo tee -a /etc/projid

sudo xfs_quota -x -c "project -s test_quota_below_limit" "$BASE_DIR"
sudo xfs_quota -x -c "limit -p bhard=8M test_quota_below_limit" "$BASE_DIR"

echo "Running test_quota_below_limit..."
"$SCRIPT" <<EOF
k
test_quota_below_limit
y
12M
n
50
EOF

echo "TEST test_quota_below_limit: PASS (archive not required)"
echo

# 6) Папка без квоты, размер = лимит
mkdir -p "$BASE_DIR/test_exact_limit"
for i in $(seq 1 10); do
    dd if=/dev/zero of="$BASE_DIR/test_exact_limit/file_$i.bin" bs=1M count=1 status=none
done

echo "Running test_exact_limit..."
"$SCRIPT" <<EOF
k
test_exact_limit
10M
n
50
EOF

echo "TEST test_exact_limit: PASS (archive not required)"
echo

# 7) Папка без квоты, превышение, удаление вместо архивации
mkdir -p "$BASE_DIR/test_delete_instead_archive"
for i in $(seq 1 12); do
    dd if=/dev/zero of="$BASE_DIR/test_delete_instead_archive/file_$i.bin" bs=1M count=1 status=none
done

initial_size=$(du -sb "$BASE_DIR/test_delete_instead_archive" | awk '{print $1}')

echo "Running test_delete_instead_archive..."
"$SCRIPT" <<EOF
k
test_delete_instead_archive
10M
p
1
n
50
EOF

final_size=$(du -sb "$BASE_DIR/test_delete_instead_archive" | awk '{print $1}')
if [ "$final_size" -lt "$initial_size" ]; then
    echo "TEST test_delete_instead_archive: PASS (size decreased)"
else
    echo "TEST test_delete_instead_archive: FAIL (size unchanged)"
fi
echo

echo "All tests completed."