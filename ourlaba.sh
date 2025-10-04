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
        echo "archive_files: текущий размер ($current) <= лимит ($limit_bytes). Ничего архивировать."
        return 0
    fi

    local need=$((current - limit_bytes))
    echo "archive_files: нужно освободить $need байт (текущий $current, лимит $limit_bytes)."

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
        echo "archive_files: ничего не найдено для архивирования."
        return 1
    fi

    local archive_dir="$BACKUP_DIR/$moment/$(basename "$folder")"
    local archive_name="$archive_dir/$(date +%Y%m%d%H%M%S).tar.gz"
    echo "archive_files: архивирую ${#files_to_archive[@]} файлов -> $archive_name"
    tar -czf "$archive_name" "${files_to_archive[@]}"
    if [ $? -eq 0 ]; then
        echo "archive_files: архив создан. Удаляю заархивированные файлы..."
        rm -f "${files_to_archive[@]}"
        echo "archive_files: удалены заархивированные файлы."
    else
        echo "archive_files: tar вернул ошибку. Архивация не выполнена."
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
        echo "delete_old_files_minimal: уже меньше лимита."
        return 0
    fi

    local need=$((current - limit_bytes))
    echo "delete_old_files_minimal: нужно удалить $need байт."

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
        echo "delete_old_files_minimal: нет файлов для удаления."
        return 1
    fi

    echo "delete_old_files_minimal: удаляю ${#del_files[@]} файлов..."
    rm -f "${del_files[@]}"
    echo "delete_old_files_minimal: удаление завершено."
    return 0
}

# ---- Основной рабочий поток ----

# 0) Проверки окружения
if ! command -v xfs_quota >/dev/null 2>&1; then
    echo "Ошибка: xfs_quota не найден. Установите пакет xfsprogs."
    exit 1
fi

if ! command -v numfmt >/dev/null 2>&1; then
    echo "Ошибка: numfmt (coreutils) не найден."
    exit 1
fi

# Убедимся, что base dir существует
if [ ! -d "$BASE_DIR" ]; then
    echo "Ошибка: BASE_DIR $BASE_DIR не найден."
    exit 1
fi

# Создаём backup если нужно
if [ ! -d "$BACKUP_DIR" ]; then
    echo "Создаю backup dir: $BACKUP_DIR"
    sudo mkdir -p "$BACKUP_DIR"
fi

# Если backup не пустой — спрашиваем что делать (единожды)
if [ "$(ls -A "$BACKUP_DIR" 2>/dev/null | wc -l)" -gt 0 ]; then
    echo "Папка $BACKUP_DIR не пуста."
    read -p "Что делать с существующими файлами в backup? (k) оставить / (d) удалить все: " bkchoice
    if [[ "$bkchoice" == "d" || "$bkchoice" == "D" ]]; then
        echo "Удаляю содержимое $BACKUP_DIR..."
        sudo rm -rf "${BACKUP_DIR:?}/"*
    else
        echo "Оставляю содержимое backup как есть."
    fi
fi







# 1) Ввод относительного пути
read -p "Введите путь к папке (относительно $BASE_DIR): " relpath

relpath="${relpath#/}"
folder="$BASE_DIR/$relpath"
proj_name=$(basename "$folder")

# 2) Создать папку если нет и сообщить
created_now=false
if [ ! -d "$folder" ]; then
    echo "Папка $folder не существует. Создаю..."
    mkdir -p "$folder"
    created_now=true
    echo "Папка создана: $folder"
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
    echo "Квота установлена: $size_str для $folder (projid=$new_id)"
}




# 4) Ветки логики
if [ -n "$proj_id" ]; then
    # Папка уже ограничена
    echo "Папка уже имеет квоту (projid=$proj_id)."
    # Попробуем показать текущий жёсткий лимит
    cur_limit_bytes=$(get_project_hard_limit_bytes "$BASE_DIR" "$proj_name" || echo "")
    if [ -n "$cur_limit_bytes" ]; then
        echo "Текущий жесткий лимит: $(to_human "$cur_limit_bytes")"
    else
        echo "Не удалось определить текущий жесткий лимит автоматически."
    fi

    read -p "Желаете изменить размер квоты? (y/n): " want_change
    if [[ "$want_change" =~ ^[Yy]$ ]]; then
        # ввод нового лимита (в цикле, если нужно)
        while true; do
            read -p "Введите новый лимит (пример 100M, 1G): " new_limit_str
            new_limit_bytes=$(to_bytes "$new_limit_str")
            if [ "$new_limit_bytes" -le 0 ]; then
                echo "Некорректный ввод. Попробуйте ещё раз."
                continue
            fi
            # сравнение с текущим размером папки
            current_size=$(folder_size_bytes "$folder")
		#size_bytes="$cur_limit_bytes"
            if [ "$current_size" -gt "$new_limit_bytes" ]; then
                echo "Внимание: текущий размер папки $(to_human "$current_size") превышает указанный лимит $(to_human "$new_limit_bytes")."
                echo "Выберите действие:"
                echo "  1) Ввести новый размер"
                echo "  2) Продолжить и затем выбрать действие: (a) удалить старые файлы или (b) архивировать старые файлы"
                read -p "Ваш выбор (1/2): " c1
                if [ "$c1" = "1" ]; then
                    continue
                else
                    # пользователь решил продолжить: спросим удалить или архивировать
                    echo "Выберите действие при превышении:"
                    echo "  d) Удалить старые файлы"
                    echo "  a) Архивировать старые файлы"
                    read -p "d/a: " da
                    if [[ "$da" == "d" ]]; then
                        delete_old_files_minimal "$folder" "$new_limit_bytes"
                    else
                        archive_files "$folder" "$new_limit_bytes" "limit_change_$(date +%Y%m%d%H%M%S)"
                    fi
                    # после удаления/архивации применяем лимит
                    sudo xfs_quota -x -c "limit -p bhard=$new_limit_str $proj_name" "$BASE_DIR"
                    size_bytes="$new_limit_bytes"
                    echo "Квота изменена на $new_limit_str"
                    break
                fi
            else
                # безопасно поменять
                sudo xfs_quota -x -c "limit -p bhard=$new_limit_str $proj_name" "$BASE_DIR"
                size_bytes="$new_limit_bytes"
                echo "Квота успешно изменена на $new_limit_str"
                break
            fi
        done
    else
        echo "Изменение квоты отменено."
        size_bytes="$cur_limit_bytes"
    fi

else
    # Папка не имела квоты
    echo "Папка не имеет квоты."
    # Ввод лимита
    while true; do
        read -p "Введите лимит для папки (например 100M, 1G): " size_str
        size_bytes=$(to_bytes "$size_str")
        if [ "$size_bytes" -le 0 ]; then
            echo "Некорректный лимит. Попробуйте ещё."
            continue
        fi
        break
    done

    # Если папка существовала до нас (created_now=false) и содержит файлы > size, нужен цикл подтверждения/изменения
    if ! $created_now; then
        current_size=$(folder_size_bytes "$folder")
        if [ "$current_size" -gt "$size_bytes" ]; then
            echo "⚠️ Папка уже содержит $(to_human "$current_size"), что больше выбранного лимита $(to_human "$size_bytes")."
            # цикл: выбирать новый размер или продолжить
            while true; do
                read -p "Вы хотите (c) изменить размер, (p) продолжить с этим размером: c/p : " ch
                if [[ "$ch" == "c" ]]; then
                    while true; do
                        read -p "Введите новый лимит: " size_str
                        size_bytes=$(to_bytes "$size_str")
                        if [ "$size_bytes" -le 0 ]; then
                            echo "Некорректный ввод."
                            continue
                        fi
                        if [ "$size_bytes" -lt 1 ]; then
                            echo "Слишком маленький."
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
                    echo "Вы выбрали продолжить. Теперь нужно выбрать действие: удалить или архивировать старые файлы (чтобы помещаться в лимит)."
                    echo "  1) Удалить старые файлы"
                    echo "  2) Архивировать старые файлы (в backup/${proj_name}/...)"
                    while true; do
                        read -p "Ваш выбор (1/2): " opt
                        if [ "$opt" = "1" ]; then
                            delete_old_files_minimal "$folder" "$size_bytes"
                            break
                        elif [ "$opt" = "2" ]; then
                            archive_files "$folder" "$size_bytes" "initial_limit_$(date +%Y%m%d%H%M%S)"
                            break
                        else
                            echo "Введите 1 или 2."
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
    echo "Регистрирую проект и ставлю квоту..."
    sudo touch "$PROJ_FILE" "$PROJID_FILE"
    proj_id=$(( $(cut -d: -f1 "$PROJ_FILE" 2>/dev/null | sort -n | tail -1 || echo 100) + 1 ))
    echo "$proj_id:$folder" | sudo tee -a "$PROJ_FILE" >/dev/null
    echo "$proj_name:$proj_id" | sudo tee -a "$PROJID_FILE" >/dev/null
    sudo xfs_quota -x -c "project -s $proj_name" "$BASE_DIR"
    sudo xfs_quota -x -c "limit -p bhard=$size_str $proj_name" "$BASE_DIR"
    echo "Квота установлена: $size_str для $folder (projid=$proj_id)"

    if $created_now; then
        echo "Папка была только что создана."
	while true; do
	    read -p "Введите размер одного файла (например 10M): " file_size_str
	    
	    if [[ ! "$file_size_str" =~ ^[0-9]+[KMG]$ ]]; then
		echo "Некорректный ввод. Формат: число + суффикс K, M или G (например 10M)"
		continue
	    fi

	    read -p "Сколько файлов создать (k)? " k
	    
	    if ! [[ "$k" =~ ^[0-9]+$ ]] || [ "$k" -le 0 ]; then
		echo "Некорректное число файлов. Введите положительное целое число."
		continue
	    fi
	    #comparing our size with folder's size
	    file_size_bytes=$(to_bytes "$file_size_str")
	    total_needed=$((file_size_bytes * k))
	    if [ "$total_needed" -gt "$size_bytes" ]; then
		echo "Суммарный размер $k файлов ($(to_human "$total_needed")) превышает лимит папки $(to_human "$size_bytes")."
		continue
	    fi
	    break
	done
        #creating of files
        for i in $(seq 1 "$k"); do
                    fname="$folder/file_$(date +%s)_$i.bin"
                    dd if=/dev/zero of="$fname" bs="$file_size_str" count=1 status=none
                    
        done
        echo "Создание файлов завершено."
    fi
fi

# --- Далее общий шаг: показать текущую информацию о папке и квоте
echo
echo "Текущий статус проекта и папки:"
sudo xfs_quota -x -c "report -p" "$BASE_DIR" || true
current_size=$(folder_size_bytes "$folder")

echo "Фактический размер папки: $(to_human "$current_size")"

# Запрос процентов n
while true; do
    read -p "Введите порог (в процентах) заполнения папки относительно лимита (1-100): " nperc
    if [[ "$nperc" =~ ^[0-9]+$ ]] && [ "$nperc" -ge 1 ] && [ "$nperc" -le 100 ]; then
        break
    fi
    echo "Введите число от 1 до 100."
done

threshold=$(( size_bytes * nperc / 100 ))
echo "Порог (n%): $(to_human "$threshold")"

# Если текущий размер > threshold -> архивируем минимальное количество старых файлов
if [ "$current_size" -gt "$threshold" ]; then
    echo "Текущий размер $(to_human "$current_size") больше порога $(to_human "$threshold")."
    echo "Архивация минимального количества старых файлов до порога..."
    # Архивация в подпапку с пометкой percent_cleanup_TIMESTAMP
    archive_files "$folder" "$threshold" "percent_cleanup_$(date +%Y%m%d%H%M%S)"
    echo "После архивации:"
    current_size=$(folder_size_bytes "$folder")
    echo "Новый размер папки: $(to_human "$current_size")"
else
    echo "Текущий размер $(to_human "$current_size") не превышает порог $(to_human "$threshold"). Ничего не делаем."
fi

# Финальный отчёт
echo
echo "Финальный отчёт по квотам:"
sudo xfs_quota -x -c "report -p" "$BASE_DIR" || true
echo "Финальный размер папки: $(to_human "$(folder_size_bytes "$folder")")"
echo "Готово."


