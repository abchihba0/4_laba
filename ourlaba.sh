#!/bin/bash
BASE_DIR="/home/alexander/newXFSdisk"
BACKUP_DIR="$BASE_DIR/backup"
PROJ_FILE="/etc/projects"
PROJID_FILE="/etc/projid"


to_bytes() {
    local s="$1"
    if [ -z "$s" ]; then return; fi
    numfmt --from=iec "$s" 2>/dev/null || {
        [[ "$s" =~ ^[0-9]+$ ]] && echo "$s" || echo "0"
    }
}

to_human() {
    local b="$1"
    numfmt --to=iec-i --suffix=B --format="%.2f" "$b" 2>/dev/null || echo "${b}B"
}

folder_size_bytes() {
    local folder="$1"
    du -sb "$folder" 2>/dev/null | awk '{print $1}' || echo 0
}

get_project_hard_limit_bytes() {
    local mp="$1"
    local projid="$2"
    local line
    line=$(xfs_quota -x -c "report -pb" "$mp" 2>/dev/null | awk -v id="$projid" '$1==id {print $4}' | head -n1)
    [[ -z "$line" || "$line" == "0" ]] && echo 0 && return
    echo $((line * 1024))
}

files_sorted_by_ctime() {
    local folder="$1"
    find "$folder" -maxdepth 1 -type f -printf "%T@ %s %p\n" 2>/dev/null | sort -n
}

archive_files() {
    local folder="$1"
    local limit_bytes="$2"
    local moment="$3"
    local current
    current=$(folder_size_bytes "$folder")
    ((current <= limit_bytes)) && return 0
    local need=$((current - limit_bytes))
    local tmp
    tmp=$(mktemp)
    files_sorted_by_ctime "$folder" > "$tmp"
    local acc=0
    local files_to_archive=()
    while IFS= read -r line; do
        local sz fpath
        sz=$(awk '{print $2}' <<< "$line")
        fpath=$(cut -d' ' -f3- <<< "$line")
        files_to_archive+=("$fpath")
        acc=$((acc + sz))
        ((acc >= need)) && break
    done < "$tmp"
    rm -f "$tmp"
    (( ${#files_to_archive[@]} == 0 )) && return 1
    local archive_dir="$BACKUP_DIR"
    local archive_name="$archive_dir/$(date +%Y%m%d%H%M%S).tar.gz"
    tar -czf "$archive_name" "${files_to_archive[@]}"
    [[ $? -eq 0 ]] && rm -f "${files_to_archive[@]}"
}

delete_old_files_minimal() {
    local folder="$1"
    local limit_bytes="$2"
    local current
    current=$(folder_size_bytes "$folder")
    ((current <= limit_bytes)) && return 0
    local need=$((current - limit_bytes))
    local tmp
    tmp=$(mktemp)
    files_sorted_by_ctime "$folder" > "$tmp"
    local acc=0
    local del_files=()
    while IFS= read -r line; do
        local sz fpath
        sz=$(awk '{print $2}' <<< "$line")
        fpath=$(cut -d' ' -f3- <<< "$line")
        del_files+=("$fpath")
        acc=$((acc + sz))
        ((acc >= need)) && break
    done < "$tmp"
    rm -f "$tmp"
    (( ${#del_files[@]} > 0 )) && rm -f "${del_files[@]}"
}


[[ ! -d "$BACKUP_DIR" ]] && mkdir -p "$BACKUP_DIR"

[[ "$(ls -A "$BACKUP_DIR" 2>/dev/null | wc -l)" -gt 0 ]] && {
    read -p "What to do with existing files in backup? (k) keep / (d) delete all: " bkchoice
    [[ "$bkchoice" =~ ^[Dd]$ ]] && rm -rf "${BACKUP_DIR:?}/"*
}

read -p "Enter folder path (relative to $BASE_DIR): " relpath
relpath="${relpath#/}"
folder="$BASE_DIR/$relpath"
proj_name=$(basename "$folder")

created_now=false
if [[ ! -d "$folder" ]]; then
    mkdir -p "$folder"
    created_now=true
fi

proj_id=""
[[ -f "$PROJID_FILE" ]] && proj_id=$(grep "^${proj_name}:" "$PROJID_FILE" 2>/dev/null | cut -d: -f2 || true)


if [[ -n "$proj_id" ]]; then
    cur_limit_bytes=$(get_project_hard_limit_bytes "$BASE_DIR" "$proj_name")
    echo "Folder already has quota (projid=$proj_id). Current limit: $(to_human "$cur_limit_bytes")"
    read -p "Do you want to change quota size? (y/n): " want_change
    if [[ "$want_change" =~ ^[Yy]$ ]]; then
        while true; do
            read -p "Enter new limit (e.g. 100M, 1G): " new_limit_str
            new_limit_bytes=$(to_bytes "$new_limit_str")
            ((new_limit_bytes > 0)) || continue
            current_size=$(folder_size_bytes "$folder")
            if ((current_size > new_limit_bytes)); then
                read -p "Current folder exceeds new limit. (d)elete old or (a)rchive files? d/a: " da
                [[ "$da" == "d" ]] && delete_old_files_minimal "$folder" "$new_limit_bytes"
                [[ "$da" == "a" ]] && archive_files "$folder" "$new_limit_bytes" "limit_change_$(date +%Y%m%d%H%M%S)"
            fi
            sudo xfs_quota -x -c "limit -p bhard=$new_limit_str $proj_name" "$BASE_DIR"
            break
        done
    fi
else
    while true; do
        read -p "Enter folder limit (e.g. 100M, 1G): " size_str
        size_bytes=$(to_bytes "$size_str")
        ((size_bytes > 0)) && break
    done

    [[ ! "$created_now" =~ true ]] && current_size=$(folder_size_bytes "$folder")
    if [[ ! "$created_now" =~ true && current_size -gt size_bytes ]]; then
        read -p "Folder exceeds limit. (c) change size or (p) proceed: c/p: " ch
        [[ "$ch" == "c" ]] && read -p "Enter new limit: " size_str && size_bytes=$(to_bytes "$size_str")
        [[ "$ch" == "p" ]] && {
            read -p "(1) Delete old files (2) Archive old files: 1/2: " opt
            [[ "$opt" == "1" ]] && delete_old_files_minimal "$folder" "$size_bytes"
            [[ "$opt" == "2" ]] && archive_files "$folder" "$size_bytes" "initial_limit_$(date +%Y%m%d%H%M%S)"
        }
    fi

    sudo touch "$PROJ_FILE" "$PROJID_FILE"
    proj_id=$(( $(cut -d: -f1 "$PROJ_FILE" 2>/dev/null | sort -n | tail -1 || echo 100) + 1 ))
    echo "$proj_id:$folder" | sudo tee -a "$PROJ_FILE" >/dev/null
    echo "$proj_name:$proj_id" | sudo tee -a "$PROJID_FILE" >/dev/null
    sudo xfs_quota -x -c "project -s $proj_name" "$BASE_DIR"
    sudo xfs_quota -x -c "limit -p bhard=$size_str $proj_name" "$BASE_DIR"

    if $created_now; then
        while true; do
            read -p "Enter single file size (e.g. 10M): " file_size_str
            [[ "$file_size_str" =~ ^[0-9]+[KMG]$ ]] || continue
            read -p "How many files to create? " k
            [[ "$k" =~ ^[0-9]+$ ]] || continue
            file_size_bytes=$(to_bytes "$file_size_str")
            ((file_size_bytes * k <= size_bytes)) || continue
            break
        done
        for i in $(seq 1 "$k"); do
            fname="$folder/file_$(date +%s)_$i.bin"
            dd if=/dev/zero of="$fname" bs="$file_size_str" count=1 status=none
        done
    fi
fi


if ! $created_now; then
    read -p "Do you want to add files to this folder? (y/n): " add_files
    [[ "$add_files" =~ ^[Yy]$ ]] && {
        while true; do
            read -p "Enter single file size (e.g. 10M): " file_size_str
            [[ "$file_size_str" =~ ^[0-9]+[KMG]$ ]] || continue
            read -p "How many files to create? " k
            [[ "$k" =~ ^[0-9]+$ ]] || continue
            file_size_bytes=$(to_bytes "$file_size_str")
            current_size=$(folder_size_bytes "$folder")
            ((current_size + file_size_bytes * k <= size_bytes)) || continue
            break
        done
        for i in $(seq 1 "$k"); do
            fname="$folder/file_$(date +%s)_$i.bin"
            dd if=/dev/zero of="$fname" bs="$file_size_str" count=1 status=none
        done
    }
fi


while true; do
    read -p "Enter threshold percent (1-100): " nperc
    [[ "$nperc" =~ ^[0-9]+$ && "$nperc" -ge 1 && "$nperc" -le 100 ]] && break
done
: "${size_bytes:=$cur_limit_bytes}"
threshold=$(( size_bytes * nperc / 100 ))
current_size=$(folder_size_bytes "$folder")
if ((current_size > threshold)); then
    echo "Current size $(to_human "$current_size") exceeds threshold $(to_human "$threshold")."
    archive_files "$folder" "$threshold" "percent_cleanup_$(date +%Y%m%d%H%M%S)"
    current_size=$(folder_size_bytes "$folder")
    echo "New folder size: $(to_human "$current_size")"
else
    echo "Current size $(to_human "$current_size") within threshold. No action needed."
fi

echo
echo "Final quota report:"
sudo xfs_quota -x -c "report -p" "$BASE_DIR"
echo "Final folder size: $(to_human "$(folder_size_bytes "$folder")")"
echo "Done."
