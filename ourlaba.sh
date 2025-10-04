#!/bin/bash
# XFS quota manager — полный скрипт (объединённый)
# Требуется: sudo для операций с /etc/projects, /etc/projid и xfs_quota
# Предполагается: BASE_DIR="/home/alexander/newXFSdisk"
# Условия: папка содержит только файлы (без подпапок)
# Backup будет в $BASE_DIR/backup
#set -euo pipefail

BASE_DIR="/home/alexander/newXFSdisk"
BACKUP_DIR="$BASE_DIR/backup"
PROJ_FILE="/etc/projects"
PROJID_FILE="/etc/projid"

# Утилиты, которые используются: numfmt, du, find, tar, xfs_quota, xfs_info, sort, awk, sed

# ---- Вспомогательные функции ----

# Преобразование человеческой единицы (e.g. 1G, 200M) в байты
to_bytes() {
    local s="$1"
    # numfmt вернёт ошибку, если пусто — тогда возвращаем 0
    if [ -z "$s" ]; then
        # echo 0
        return
    fi
    numfmt --from=iec "$s" 2>/dev/null || {
        # Попробуем как целое число байт
        if [[ "$s" =~ ^[0-9]+$ ]]; then
            echo "$s"
        else
            echo "0"
        fi
    }
}

# Читабельное представление байт
to_human() {
    local b="$1"
    numfmt --to=iec-i --suffix=B --format="%.2f" "$b" 2>/dev/null || echo "${b}B"
}

# Получить текущий размер папки в байтах
folder_size_bytes() {
    local folder="$1"
    du -sb "$folder" 2>/dev/null | awk '{print $1}' || echo 0
}

# Получить blocksize файловой системы в байтах
get_xfs_blocksize() {
    local mp="$1"
    # xfs_info выводит строку с bsize=####
    local out
    out=$(xfs_info "$mp" 2>/dev/null || true)
    # Попробуем найти bsize=NUM или bsize=NUM,
    local bsize
    bsize=$(printf '%s\n' "$out" | sed -n 's/.*bsize=\([0-9]\+\).*/\1/p' | head -n1 || true)
    if [[ -z "$bsize" ]]; then
        # fallback: 1024
        echo 1024
    else
        echo "$bsize"
    fi
}

# Получить текущий жесткий лимит проекта (в байтах), если он установлен; пустая строка если нет
get_project_hard_limit_bytes() {
    local mp="$1"
    local projid="$2"
    # Берём четвёртую колонку (Hard) из отчёта, в KiB
    local line
    line=$(xfs_quota -x -c "report -pb" "$mp" 2>/dev/null | awk -v id="$projid" '$1==id {print $4}' | head -n1)
    if [[ -z "$line" || "$line" == "0" ]]; then
        echo 0
        return
    fi
    # Переводим в байты
    echo $((line * 1024))
}


# Получить список файлов (старые первые) с их size и path
# выводит строки: "<ctime> <size> <path>"
files_sorted_by_ctime() {
    local folder="$1"
    # используем %T@ (modtime) — на практике подходит; если нужен именно ctime — заменить на %C@
    find "$folder" -maxdepth 1 -type f -printf "%T@ %s %p\n" 2>/dev/null | sort -n
}

# ---- Функция архивирования (единая) ----
# archive_files <folder> <limit_bytes> <moment_label>
# Сохраняет архив(ы) в $BACKUP_DIR/<moment_label>/<basename(folder)>/<timestamp>.tar.gz
archive_files() {
    local folder="$1"
    local limit_bytes="$2"
    local moment="$3"

    mkdir -p "$BACKUP_DIR/$moment/$(basename "$folder")"

    local current
    current=$(folder_size_bytes "$folder")
    if [ "$current" -le "$limit_bytes" ]; then
        echo "archive_files: current size ($current) <= limit ($limit_bytes). Nothing to archive."
        return 0
    fi

    local need=$((current - limit_bytes))
    echo "archive_files: need to free $need bytes (current $current, limit $limit_bytes)."

    local tmp
    tmp=$(mktemp)
    files_sorted_by_ctime "$folder" > "$tmp"

    local acc=0
    local files_to_archive=()
    while IFS= read -r line; do
        local sz
        local fpath
        sz=$(printf '%s' "$line" | awk '{print $2}')
        fpath=$(printf '%s' "$line" | cut -d' ' -f3-)
        files_to_archive+=("$fpath")
        acc=$((acc + sz))
        if [ "$acc" -ge "$need" ]; then
            break
        fi
    done < "$tmp"
    rm -f "$tmp"

    if [ "${#files_to_archive[@]}" -eq 0 ]; then
        echo "archive_files: nothing found to archive."
        return 1
    fi

    local archive_dir="$BACKUP_DIR/$moment/$(basename "$folder")"
    local archive_name="$archive_dir/$(date +%Y%m%d%H%M%S).tar.gz"
    echo "archive_files: archiving ${#files_to_archive[@]} files -> $archive_name"
    tar -czf "$archive_name" "${files_to_archive[@]}"
    if [ $? -eq 0 ]; then
        echo "archive_files: archive created. Removing archived files..."
        rm -f "${files_to_archive[@]}"
        echo "archive_files: archived files removed."
    else
        echo "archive_files: tar returned error. Archiving failed."
        return 2
    fi
    return 0
}

# ---- Удаление минимального набора старых файлов ----
# delete_old_files_minimal <folder> <limit_bytes>
delete_old_files_minimal() {
    local folder="$1"
    local limit_bytes="$2"

    local current
    current=$(folder_size_bytes "$folder")
    if [ "$current" -le "$limit_bytes" ]; then
        echo "delete_old_files_minimal: already below limit."
        return 0
    fi

    local need=$((current - limit_bytes))
    echo "delete_old_files_minimal: need to delete $need bytes."

    local tmp
    tmp=$(mktemp)
    files_sorted_by_ctime "$folder" > "$tmp"

    local acc=0
    local del_files=()
    while IFS= read -r line; do
        local sz
        local fpath
        sz=$(printf '%s' "$line" | awk '{print $2}')
        fpath=$(printf '%s' "$line" | cut -d' ' -f3-)
        del_files+=("$fpath")
        acc=$((acc + sz))
        if [ "$acc" -ge "$need" ]; then
            break
        fi
    done < "$tmp"
    rm -f "$tmp"

    if [ "${#del_files[@]}" -eq 0 ]; then
        echo "delete_old_files_minimal: no files to delete."
        return 1
    fi

    echo "delete_old_files_minimal: deleting ${#del_files[@]} files..."
    rm -f "${del_files[@]}"
    echo "delete_old_files_minimal: deletion completed."
    return 0
}

# ---- Основной рабочий поток ----

# 0) Проверки окружения
if ! command -v xfs_quota >/dev/null 2>&1; then
    echo "Error: xfs_quota not found. Install xfsprogs package."
    exit 1
fi

if ! command -v numfmt >/dev/null 2>&1; then
    echo "Error: numfmt (coreutils) not found."
    exit 1
fi

# Убедимся, что base dir существует
if [ ! -d "$BASE_DIR" ]; then
    echo "Error: BASE_DIR $BASE_DIR not found."
    exit 1
fi

# Создаём backup если нужно
if [ ! -d "$BACKUP_DIR" ]; then
    echo "Creating backup dir: $BACKUP_DIR"
    sudo mkdir -p "$BACKUP_DIR"
fi

# Если backup не пустой — спрашиваем что делать (единожды)
if [ "$(ls -A "$BACKUP_DIR" 2>/dev/null | wc -l)" -gt 0 ]; then
    echo "Directory $BACKUP_DIR is not empty."
    read -p "What to do with existing files in backup? (k) keep / (d) delete all: " bkchoice
    if [[ "$bkchoice" == "d" || "$bkchoice" == "D" ]]; then
        echo "Deleting contents of $BACKUP_DIR..."
        sudo rm -rf "${BACKUP_DIR:?}/"*
    else
        echo "Keeping backup contents as is."
    fi
fi







# 1) Ввод относительного пути
read -p "Enter folder path (relative to $BASE_DIR): " relpath

relpath="${relpath#/}"
folder="$BASE_DIR/$relpath"
proj_name=$(basename "$folder")

# 2) Создать папку если нет и сообщить
created_now=false
if [ ! -d "$folder" ]; then
    echo "Folder $folder does not exist. Creating..."
    mkdir -p "$folder"
    created_now=true
    echo "Folder created: $folder"
else
    echo "Folder $folder exists."
fi

# 3) Проверяем существующую квоту по projid
proj_id=""
if [ -f "$PROJID_FILE" ]; then
    proj_id=$(grep "^${proj_name}:" "$PROJID_FILE" 2>/dev/null | cut -d: -f2 || true)
fi


# Функция установки квоты по имени проекта + запись в /etc/projects и /etc/projid
set_quota_for_folder() {
    local folder="$1"
    local proj_name="$2"
    local size_str="$3"   #  e.g. 1G, 200M
    # ensure /etc/projects and /etc/projid exist
    sudo touch "$PROJ_FILE" "$PROJID_FILE"
    # compute proj_id
    local new_id
    new_id=$(( $(cut -d: -f1 "$PROJ_FILE" 2>/dev/null | sort -n | tail -1 || echo 100) + 1 ))
    # append mapping
    echo "$new_id:$folder" | sudo tee -a "$PROJ_FILE" >/dev/null
    echo "$proj_name:$new_id" | sudo tee -a "$PROJID_FILE" >/dev/null
    sudo xfs_quota -x -c "project -s $proj_name" "$BASE_DIR"
    sudo xfs_quota -x -c "limit -p bhard=$size_str $proj_name" "$BASE_DIR"
    echo "Quota set: $size_str for $folder (projid=$new_id)"
}




# 4) Ветки логики
if [ -n "$proj_id" ]; then
    # Папка уже ограничена
    echo "Folder already has quota (projid=$proj_id)."
    # Выравниваем владельца проекта, чтобы избежать Permission denied
    chown -R "$SUDO_USER":"$SUDO_USER" "$folder"

    # Попробуем показать текущий жёсткий лимит
    cur_limit_bytes=$(get_project_hard_limit_bytes "$BASE_DIR" "$proj_name" || echo "")
    if [ -n "$cur_limit_bytes" ]; then
        echo "Current hard limit: $(to_human "$cur_limit_bytes")"
    else
        echo "Failed to determine current hard limit automatically."
    fi

    read -p "Do you want to change quota size? (y/n): " want_change
    if [[ "$want_change" =~ ^[Yy]$ ]]; then
        # ввод нового лимита (в цикле, если нужно)
        while true; do
            read -p "Enter new limit (example 100M, 1G): " new_limit_str
            new_limit_bytes=$(to_bytes "$new_limit_str")
            if [ "$new_limit_bytes" -le 0 ]; then
                echo "Invalid input. Please try again."
                continue
            fi
            # сравнение с текущим размером папки
            current_size=$(folder_size_bytes "$folder")
		#size_bytes="$cur_limit_bytes"
            if [ "$current_size" -gt "$new_limit_bytes" ]; then
                echo "Warning: current folder size $(to_human "$current_size") exceeds specified limit $(to_human "$new_limit_bytes")."
                echo "Choose action:"
                echo "  1) Enter new size"
                echo "  2) Continue and then choose: (a) delete old files or (b) archive old files"
                read -p "Your choice (1/2): " c1
                if [ "$c1" = "1" ]; then
                    continue
                else
                    # пользователь решил продолжить: спросим удалить или архивировать
                    echo "Choose action when exceeding limit:"
                    echo "  d) Delete old files"
                    echo "  a) Archive old files"
                    read -p "d/a: " da
                    if [[ "$da" == "d" ]]; then
                        delete_old_files_minimal "$folder" "$new_limit_bytes"
                    else
                        archive_files "$folder" "$new_limit_bytes" "limit_change_$(date +%Y%m%d%H%M%S)"
                    fi
                    # после удаления/архивации применяем лимит
                    sudo xfs_quota -x -c "limit -p bhard=$new_limit_str $proj_name" "$BASE_DIR"
                    size_bytes="$new_limit_bytes"
                    echo "Quota changed to $new_limit_str"
                    break
                fi
            else
                # безопасно поменять
                sudo xfs_quota -x -c "limit -p bhard=$new_limit_str $proj_name" "$BASE_DIR"
                size_bytes="$new_limit_bytes"
                echo "Quota successfully changed to $new_limit_str"
                break
            fi
        done
    else
        echo "Quota change cancelled."
        size_bytes="$cur_limit_bytes"
    fi

else
    # Папка не имела квоты
    echo "Folder has no quota."
    # Ввод лимита
    while true; do
        read -p "Enter folder limit (e.g. 100M, 1G): " size_str
        size_bytes=$(to_bytes "$size_str")
        if [ "$size_bytes" -le 0 ]; then
            echo "Invalid limit. Please try again."
            continue
        fi
        break
    done

    # Если папка существовала до нас (created_now=false) и содержит файлы > size, нужен цикл подтверждения/изменения
    if ! $created_now; then
        current_size=$(folder_size_bytes "$folder")
        if [ "$current_size" -gt "$size_bytes" ]; then
            echo " Folder already contains $(to_human "$current_size"), which exceeds selected limit $(to_human "$size_bytes")."
            # цикл: выбирать новый размер или продолжить
            while true; do
                read -p "Do you want to (c) change size, (p) proceed with this size: c/p : " ch
                if [[ "$ch" == "c" ]]; then
                    while true; do
                        read -p "Enter new limit: " size_str
                        size_bytes=$(to_bytes "$size_str")
                        if [ "$size_bytes" -le 0 ]; then
                            echo "Invalid input."
                            continue
                        fi
                        if [ "$size_bytes" -lt 1 ]; then
                            echo "Too small."
                            continue
                        fi
                        break
                    done
                    # если новый лимит теперь больше или равен текущего размера — можем выйти
                    if [ "$(folder_size_bytes "$folder")" -le "$size_bytes" ]; then
                        break
                    fi
                    # иначе цикл продолжается — снова спрашиваем change/continue
                else
                    # пользователь выбрал продолжить с текущим size_bytes
                    echo "You chose to proceed. Now choose action: delete or archive old files (to fit within limit)."
                    echo "  1) Delete old files"
                    echo "  2) Archive old files (to backup/${proj_name}/...)"
                    while true; do
                        read -p "Your choice (1/2): " opt
                        if [ "$opt" = "1" ]; then
                            delete_old_files_minimal "$folder" "$size_bytes"
                            break
                        elif [ "$opt" = "2" ]; then
                            archive_files "$folder" "$size_bytes" "initial_limit_$(date +%Y%m%d%H%M%S)"
                            break
                        else
                            echo "Enter 1 or 2."
                        fi
                    done
                    break
                fi
            done
        fi
    else
        # папка была создана только сейчас — после создания квоты будет запрос про заполнение файлами (ниже)
        :
    fi

    # Теперь устанавливаем квоту (создаём записи)
    echo "Registering project and setting quota..."
    sudo touch "$PROJ_FILE" "$PROJID_FILE"
    proj_id=$(( $(cut -d: -f1 "$PROJ_FILE" 2>/dev/null | sort -n | tail -1 || echo 100) + 1 ))
    echo "$proj_id:$folder" | sudo tee -a "$PROJ_FILE" >/dev/null
    echo "$proj_name:$proj_id" | sudo tee -a "$PROJID_FILE" >/dev/null
    sudo xfs_quota -x -c "project -s $proj_name" "$BASE_DIR"
    sudo xfs_quota -x -c "limit -p bhard=$size_str $proj_name" "$BASE_DIR"
    echo "Quota set: $size_str for $folder (projid=$proj_id)"

    if $created_now; then
        echo "Folder was just created."
	while true; do
	    read -p "Enter single file size (e.g. 10M): " file_size_str
	    
	    if [[ ! "$file_size_str" =~ ^[0-9]+[KMG]$ ]]; then
		echo "Invalid input. Format: number + suffix K, M or G (e.g. 10M)"
		continue
	    fi

	    read -p "How many files to create (k)? " k
	    
	    if ! [[ "$k" =~ ^[0-9]+$ ]] || [ "$k" -le 0 ]; then
		echo "Invalid number of files. Enter positive integer."
		continue
	    fi
	    #comparing our size with folder's size
	    file_size_bytes=$(to_bytes "$file_size_str")
	    total_needed=$((file_size_bytes * k))
	    if [ "$total_needed" -gt "$size_bytes" ]; then
		echo "Total size of $k files ($(to_human "$total_needed")) exceeds folder limit $(to_human "$size_bytes")."
		continue
	    fi
	    break
	done
        #creating of files
        for i in $(seq 1 "$k"); do
                    fname="$folder/file_$(date +%s)_$i.bin"
                    dd if=/dev/zero of="$fname" bs="$file_size_str" count=1 status=none
                    
        done
        echo "File creation completed."
    fi
fi

# --- Далее общий шаг: показать текущую информацию о папке и квоте
echo
echo "Current project and folder status:"
sudo xfs_quota -x -c "report -p" "$BASE_DIR" || true
current_size=$(folder_size_bytes "$folder")

echo "Actual folder size: $(to_human "$current_size")"


# Предложение добавить файлы в проект (только если папка не новая)
if ! $created_now; then
    read -p "Do you want to add files to this folder? (y/n): " add_files
    if [[ "$add_files" =~ ^[Yy]$ ]]; then
        while true; do
            read -p "Enter single file size (e.g. 10M): " file_size_str

            if [[ ! "$file_size_str" =~ ^[0-9]+[KMG]$ ]]; then
                echo "Invalid input. Format: number + suffix K, M or G (e.g. 10M)"
                continue
            fi

            read -p "How many files to create (k)? " k

            if ! [[ "$k" =~ ^[0-9]+$ ]] || [ "$k" -le 0 ]; then
                echo "Invalid number of files. Enter positive integer."
                continue
            fi

            # Проверяем, не превышает ли суммарный размер лимит квоты
            file_size_bytes=$(to_bytes "$file_size_str")
            total_needed=$((file_size_bytes * k))
            if [ "$((current_size + total_needed))" -gt "$size_bytes" ]; then
                echo "Total size of $k new files ($(to_human "$total_needed")) + current size ($(to_human "$current_size")) exceeds folder limit $(to_human "$size_bytes")."
                echo "Please choose smaller files or fewer files."
                continue
            fi
            break
        done

        echo "Creating $k files of size $file_size_str..."
        for i in $(seq 1 "$k"); do
            fname="$folder/file_$(date +%s)_$i.bin"
            dd if=/dev/zero of="$fname" bs="$file_size_str" count=1 status=none
        done
        echo "File creation completed."

        # Обновляем текущий размер папки после добавления файлов
        current_size=$(folder_size_bytes "$folder")
        echo "Updated folder size: $(to_human "$current_size")"
    fi
fi



echo "Current project and folder status:"
sudo xfs_quota -x -c "report -p" "$BASE_DIR" || true
current_size=$(folder_size_bytes "$folder")

echo "Actual folder size: $(to_human "$current_size")"






# Запрос процентов n
while true; do
    read -p "Enter threshold (in percent) of folder usage relative to limit (1-100): " nperc
    if [[ "$nperc" =~ ^[0-9]+$ ]] && [ "$nperc" -ge 1 ] && [ "$nperc" -le 100 ]; then
        break
    fi
    echo "Enter number from 1 to 100."
done

threshold=$(( size_bytes * nperc / 100 ))
echo "Threshold (n%): $(to_human "$threshold")"

# Если текущий размер > threshold -> архивируем минимальное количество старых файлов
if [ "$current_size" -gt "$threshold" ]; then
    echo "Current size $(to_human "$current_size") exceeds threshold $(to_human "$threshold")."
    echo "Archiving minimal number of old files to reach threshold..."
    # Архивация в подпапку с пометкой percent_cleanup_TIMESTAMP
    archive_files "$folder" "$threshold" "percent_cleanup_$(date +%Y%m%d%H%M%S)"
    echo "After archiving:"
    current_size=$(folder_size_bytes "$folder")
    echo "New folder size: $(to_human "$current_size")"
else
    echo "Current size $(to_human "$current_size") does not exceed threshold $(to_human "$threshold"). No action needed."
fi

# Финальный отчёт
echo
echo "Final quota report:"
sudo xfs_quota -x -c "report -p" "$BASE_DIR" || true
echo "Final folder size: $(to_human "$(folder_size_bytes "$folder")")"
echo "Done."
