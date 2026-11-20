#!/usr/bin/env bash
#
#  PrikolProvider dotfiles installer
#  By PrikolProvider
#
#  Кратко: показывает анимированный баннер, ждёт Enter и ставит конфиги.
#
#  Флаги:
#    --dry-run       показать, что будет сделано (без изменений)
#    --packages      поставить пакеты pacman
#    --aur           поставить AUR-пакеты (нужен yay/paru)
#    --flatpak       поставить flatpak-приложения
#    --serpantinum   поставить Serpantinum из upstream
#    --shell         сделать fish шеллом по умолчанию
#    --no-intro      без анимации
#    --no-color      без цветов
#    --verbose       показывать выполняемые команды
#    -y, --yes       без ожидания Enter
#    -h, --help      эта справка
#
set -euo pipefail

DOTFILES="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
VERSION="1.0"
BRAND="By PrikolProvider"

BACKUP_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles-backup"
BACKUP="$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)"
WALLPAPER_DIR="${XDG_PICTURES_DIR:-$HOME/Pictures}/Wallpapers"

DO_PACKAGES=0
DO_AUR=0
DO_FLATPAK=0
DO_SERPANTINUM=0
DO_SHELL=0
DRY_RUN=0
ASSUME_YES=0
NO_INTRO=0
VERBOSE=0
USE_COLOR=1

BACKED_UP=0
START_TIME=$SECONDS

# ─── цвета ───────────────────────────────────────────────────────────────────

if [[ ! -t 1 || -n "${NO_COLOR:-}" || "${TERM:-dumb}" == "dumb" ]]; then
    USE_COLOR=0
fi

setup_colors() {
    if (( USE_COLOR )); then
        R=$'\033[0m'; B=$'\033[1m'; D=$'\033[2m'
        PINK=$'\033[38;5;213m'; PURPLE=$'\033[38;5;141m'
        BLUE=$'\033[38;5;111m'; GREEN=$'\033[38;5;114m'
        YELLOW=$'\033[38;5;221m'; RED=$'\033[38;5;203m'
        GREY=$'\033[38;5;245m'; WHITE=$'\033[97m'
    else
        R=""; B=""; D=""; PINK=""; PURPLE=""; BLUE=""
        GREEN=""; YELLOW=""; RED=""; GREY=""; WHITE=""
    fi
}
setup_colors

say()  { printf '  %s→%s %s\n' "$PURPLE" "$R" "$*"; }
ok()   { printf '  %s✓%s %s\n' "$GREEN" "$R" "$*"; }
warn() { printf '  %s!%s %s\n' "$YELLOW" "$R" "$*"; }
item() { printf '    %s·%s %s\n' "$GREY" "$R" "$*"; }
die()  { printf '\n  %s✗ Ошибка:%s %s\n\n' "$RED" "$R" "$*" >&2; exit 1; }

# Тихая команда: вывод скрывается, при ошибке показывается только она.
run() {
    (( VERBOSE )) && printf '    %s+%s %s\n' "$GREY" "$R" "$*"
    (( DRY_RUN )) && return 0
    local out
    if ! out="$("$@" 2>&1)"; then
        printf '\n  %s✗ Ошибка:%s %s\n%s\n' "$RED" "$R" "$*" "$out" >&2
        return 1
    fi
}

# Громкая команда: нужна там, где есть sudo/интерактив/долгий вывод.
run_loud() {
    if (( DRY_RUN )); then
        printf '    %s+%s %s\n' "$GREY" "$R" "$*"
        return 0
    fi
    "$@"
}

# Команда, ошибка которой не критична (gsettings и т.п.).
try_run() {
    (( VERBOSE )) && printf '    %s+%s %s\n' "$GREY" "$R" "$*"
    (( DRY_RUN )) && return 0
    "$@" >/dev/null 2>&1 || true
}

# Спиннер для долгих тихих операций.
spin() {
    local msg="$1"; shift

    if (( ! USE_COLOR )) || [[ ! -t 1 ]]; then
        "$@"
        return
    fi

    local log rc=0 pid i=0
    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    log="$(mktemp)"

    "$@" >"$log" 2>&1 &
    pid=$!

    while kill -0 "$pid" 2>/dev/null; do
        printf '\r  %s%s%s %s   ' "$PURPLE" "${frames[i % ${#frames[@]}]}" "$R" "$msg"
        i=$((i + 1))
        sleep 0.08
    done
    wait "$pid" || rc=$?
    printf '\r\033[K'

    if (( rc != 0 )); then
        printf '  %s✗%s %s\n' "$RED" "$R" "$msg" >&2
        sed 's/^/    /' "$log" >&2 || true
    fi
    rm -f "$log"
    return "$rc"
}

clear_screen() {
    if [[ -t 1 ]]; then
        printf '\033[2J\033[H'
    fi
}

usage() {
    sed -n '8,19p' "${BASH_SOURCE[0]}" | sed 's/^#  //'
    exit 0
}

while (($#)); do
    case "$1" in
        -h|--help)      usage ;;
        --dry-run)      DRY_RUN=1 ;;
        --packages)     DO_PACKAGES=1 ;;
        --aur)          DO_AUR=1 ;;
        --flatpak)      DO_FLATPAK=1 ;;
        --serpantinum)  DO_SERPANTINUM=1 ;;
        --shell)        DO_SHELL=1 ;;
        --no-intro)     NO_INTRO=1 ;;
        --no-color)     USE_COLOR=0; setup_colors ;;
        --verbose)      VERBOSE=1 ;;
        -y|--yes)       ASSUME_YES=1 ;;
        *)              die "Неизвестный аргумент: $1 (см. --help)" ;;
    esac
    shift
done

# ─── система ─────────────────────────────────────────────────────────────────

os_name() {
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release && printf '%s' "${PRETTY_NAME:-Linux}"
    else
        printf 'Linux'
    fi
}

session_name() {
    printf '%s' "${XDG_CURRENT_DESKTOP:-${XDG_SESSION_DESKTOP:-неизвестно}}"
}

serpantinum_status() {
    if command -v serpantinumd >/dev/null 2>&1; then
        printf '%s✓ установлен%s' "$GREEN" "$R"
    else
        printf '%s✗ не найден%s' "$RED" "$R"
    fi
}

# ─── анимированный интро ─────────────────────────────────────────────────────

intro() {
    (( NO_INTRO )) && return 0
    [[ -t 1 ]] || return 0

    local lines=(
        '   ██████╗ ██████╗ ██╗██╗  ██╗ ██████╗ ██╗'
        '   ██╔══██╗██╔══██╗██║██║ ██╔╝██╔═══██╗██║'
        '   ██████╔╝██████╔╝██║█████╔╝ ██║   ██║██║'
        '   ██╔═══╝ ██╔══██╗██║██╔═██╗ ██║   ██║██║'
        '   ██║     ██║  ██║██║██║  ██╗╚██████╔╝███████╗'
        '   ╚═╝     ╚═╝  ╚═╝╚═╝╚═╝  ╚═╝ ╚═════╝ ╚══════╝'
    )
    local colors=("$PINK" "$PINK" "$PINK" "$PURPLE" "$BLUE" "$BLUE")

    local l width=0 cols rows pad top i
    for l in "${lines[@]}"; do
        (( ${#l} > width )) && width=${#l}
    done

    cols=$(tput cols 2>/dev/null || printf 80)
    rows=$(tput lines 2>/dev/null || printf 24)
    pad=$(( (cols - width) / 2 ))
    (( pad < 0 )) && pad=0
    top=$(( (rows - 17) / 2 ))
    (( top < 0 )) && top=0

    clear_screen
    for ((i = 0; i < top; i++)); do printf '\n'; done

    local j len
    for i in "${!lines[@]}"; do
        l="${lines[$i]}"
        len=${#l}
        for ((j = 1; j <= len; j++)); do
            printf '\r%*s%s%s%s' "$pad" "" "${colors[$i]}" "${l:0:j}" "$R"
            sleep 0.004
        done
        printf '\n'
        sleep 0.04
    done

    printf '\n'
    printf '%*s%s%s%s\n' "$pad" "" "$B" "PrikolProvider dotfiles" "$R"
    sleep 0.08
    printf '%*s%sHyprland + Serpantinum%s  %s·%s  %sArch / CachyOS%s\n' \
        "$pad" "" "$WHITE" "$R" "$GREY" "$R" "$GREY" "$R"
    sleep 0.08
    printf '%*s%s%s%s  %s·%s  %sv%s%s\n' \
        "$pad" "" "$PINK" "$BRAND" "$R" "$GREY" "$R" "$GREY" "$VERSION" "$R"
    sleep 0.12

    printf '\n%*s%s┌─ Система%s\n' "$pad" "" "$GREY" "$R"
    printf '%*s%s│%s  Дистрибутив   %s\n' "$pad" "" "$GREY" "$R" "$(os_name)"
    printf '%*s%s│%s  Сессия        %s\n' "$pad" "" "$GREY" "$R" "$(session_name)"
    printf '%*s%s│%s  Serpantinum   %b\n' "$pad" "" "$GREY" "$R" "$(serpantinum_status)"
    printf '%*s%s│%s  Репозиторий   %s\n' "$pad" "" "$GREY" "$R" "$DOTFILES"
    printf '%*s%s└─%s\n' "$pad" "" "$GREY" "$R"

    if (( DRY_RUN )); then
        printf '\n%*s%s! Режим --dry-run: ничего не изменится%s\n' "$pad" "" "$YELLOW" "$R"
    fi

    if (( ! ASSUME_YES )); then
        printf '\n%*s%sНажми %sEnter%s, чтобы начать установку%s\n' \
            "$pad" "" "$B" "$PINK" "$B" "$R"
    fi
}

# ─── компактная шапка после Enter ────────────────────────────────────────────

header() {
    clear_screen
    printf '\n  %s%s%s  %s·%s  %s%s%s  %s·%s  %sv%s%s\n' \
        "$B" "PrikolProvider dotfiles" "$R" \
        "$GREY" "$R" \
        "$PINK" "$BRAND" "$R" \
        "$GREY" "$R" "$GREY" "$VERSION" "$R"
    printf '  %s%s%s\n\n' "$GREY" "$(printf '─%.0s' $(seq 1 56))" "$R"
    if (( DRY_RUN )); then
        printf '  %s! dry-run: команды не выполняются%s\n\n' "$YELLOW" "$R"
    fi
}

# ─── шаги ────────────────────────────────────────────────────────────────────

TOTAL_STEPS=6
if (( DO_PACKAGES || DO_AUR || DO_FLATPAK )); then
    TOTAL_STEPS=$((TOTAL_STEPS + 1))
fi
STEP=0

step() {
    STEP=$((STEP + 1))
    printf '\n%s▸%s %s[%d/%d]%s %s%s%s\n' \
        "$PURPLE" "$R" "$GREY" "$STEP" "$TOTAL_STEPS" "$R" "$B" "$1" "$R"
}

# ─── бэкап ───────────────────────────────────────────────────────────────────

backup_item() {
    local src="$1" name="$2"
    [[ -e "$src" || -L "$src" ]] || return 0
    (( DRY_RUN )) || BACKED_UP=$((BACKED_UP + 1))
    local dst="$BACKUP/$name"
    run mkdir -p "$(dirname "$dst")"
    run mv "$src" "$dst"
}

# ─── копирование ─────────────────────────────────────────────────────────────

copy_tree() {
    local src="$1" dst="$2"
    run mkdir -p "$dst"
    if command -v rsync >/dev/null 2>&1; then
        run rsync -a "$src/" "$dst/"
    else
        run cp -a "$src/." "$dst/"
    fi
}

# Заменяем жёстко прописанный /home/pacan на реальный $HOME.
patch_paths() {
    local target="$1"
    (( DRY_RUN )) && return 0
    if [[ -f "$target" ]]; then
        grep -Iq . "$target" 2>/dev/null || return 0
        sed -i "s|/home/pacan|$HOME|g" "$target"
    elif [[ -d "$target" ]]; then
        grep -rlIZ "/home/pacan" "$target" 2>/dev/null \
            | xargs -0 -r sed -i "s|/home/pacan|$HOME|g" || true
    fi
}

# ─── конфиги ─────────────────────────────────────────────────────────────────

install_configs() {
    step "Конфиги → ~/.config"
    local src name dst count=0

    for src in "$DOTFILES"/config/*; do
        [[ -e "$src" ]] || continue
        name="$(basename "$src")"
        dst="$HOME/.config/$name"

        backup_item "$dst" "config/$name"

        if [[ -d "$src" ]]; then
            copy_tree "$src" "$dst"
        else
            run mkdir -p "$HOME/.config"
            run cp -a "$src" "$dst"
        fi
        patch_paths "$dst"
        count=$((count + 1))
    done

    ok "$count конфигов"
}

# ─── домашние дотфайлы ───────────────────────────────────────────────────────

install_home() {
    step "Дотфайлы → ~"
    local f name count=0

    shopt -s dotglob nullglob
    for f in "$DOTFILES"/home/*; do
        name="$(basename "$f")"

        # gitconfig не перезаписываем: у каждого свой git-identity
        if [[ "$name" == ".gitconfig" ]]; then
            if [[ -e "$HOME/.gitconfig" ]]; then
                warn "~/.gitconfig уже есть — не трогаю"
                continue
            fi
            run cp -a "$f" "$HOME/$name"
            count=$((count + 1))
            continue
        fi

        backup_item "$HOME/$name" "home/$name"
        run cp -a "$f" "$HOME/$name"
        patch_paths "$HOME/$name"
        count=$((count + 1))
    done
    shopt -u dotglob nullglob

    ok "$count файлов"
}

# ─── скрипты ─────────────────────────────────────────────────────────────────

install_bin() {
    step "Скрипты → ~/.local/bin"
    local f name count=0

    run mkdir -p "$HOME/.local/bin"
    for f in "$DOTFILES"/bin/*; do
        [[ -e "$f" ]] || continue
        name="$(basename "$f")"
        if [[ -e "$HOME/.local/bin/$name" ]]; then
            backup_item "$HOME/.local/bin/$name" "bin/$name"
        fi
        run cp -a "$f" "$HOME/.local/bin/$name"
        run chmod +x "$HOME/.local/bin/$name"
        count=$((count + 1))
    done

    ok "$count скриптов"
}

# ─── обои ────────────────────────────────────────────────────────────────────

copy_wallpapers() {
    local dir
    for dir in "$DOTFILES"/wallpapers/*; do
        [[ -d "$dir" ]] || continue
        if command -v rsync >/dev/null 2>&1; then
            rsync -a --ignore-existing "$dir/" "$WALLPAPER_DIR/"
        else
            cp -an "$dir/." "$WALLPAPER_DIR/"
        fi
    done
}

install_wallpapers() {
    step "Обои → $WALLPAPER_DIR"
    [[ -d "$DOTFILES/wallpapers" ]] || { warn "папки wallpapers нет"; return 0; }

    local count
    count="$(find "$DOTFILES/wallpapers" -type f | wc -l)"

    if (( DRY_RUN )); then
        ok "будет скопировано $count обоев"
        return 0
    fi

    run mkdir -p "$WALLPAPER_DIR"
    spin "Копирую $count обоев…" copy_wallpapers
    ok "$count обоев"
}

# ─── пакеты ──────────────────────────────────────────────────────────────────

install_all_packages() {
    step "Пакеты"

    if (( DO_PACKAGES )); then
        command -v pacman >/dev/null 2>&1 || die "pacman не найден — это не Arch-подобная система."
        warn "Список собран на CachyOS: часть пакетов есть не в каждом репозитории."
        say "pacman: $(wc -l < "$DOTFILES/packages/pacman.txt") пакетов"
        mapfile -t pkgs < "$DOTFILES/packages/pacman.txt"
        run_loud sudo pacman -S --needed --noconfirm "${pkgs[@]}"
        ok "pacman готов"
    fi

    if (( DO_AUR )); then
        local helper=""
        if command -v paru >/dev/null 2>&1; then helper=paru
        elif command -v yay >/dev/null 2>&1; then helper=yay
        else die "Нужен yay или paru для AUR."
        fi
        say "AUR через $helper: $(wc -l < "$DOTFILES/packages/aur.txt") пакетов"
        mapfile -t pkgs < "$DOTFILES/packages/aur.txt"
        run_loud "$helper" -S --needed --noconfirm "${pkgs[@]}"
        ok "AUR готов"
    fi

    if (( DO_FLATPAK )); then
        command -v flatpak >/dev/null 2>&1 || die "flatpak не найден."
        say "flatpak: $(wc -l < "$DOTFILES/packages/flatpak.txt") приложений"
        mapfile -t pkgs < "$DOTFILES/packages/flatpak.txt"
        run_loud flatpak install -y flathub "${pkgs[@]}"
        ok "flatpak готов"
    fi
}

# ─── serpantinum ─────────────────────────────────────────────────────────────

install_serpantinum() {
    step "Serpantinum"

    if command -v serpantinumd >/dev/null 2>&1; then
        ok "уже установлен: $(command -v serpantinumd)"
        return 0
    fi

    warn "не установлен"
    if (( DO_SERPANTINUM )); then
        say "ставлю из upstream"
        run_loud bash -c 'curl -fsSL install.serpantinum.dev | bash'
        ok "готово"
    else
        item "поставить: ./install.sh --serpantinum"
        item "вручную:   curl -fsSL install.serpantinum.dev | bash"
    fi
}

# ─── финал ───────────────────────────────────────────────────────────────────

apply_theme() {
    command -v gsettings >/dev/null 2>&1 || return 0
    say "GTK-тема, иконки и курсор"
    try_run gsettings set org.gnome.desktop.interface gtk-theme "adw-gtk3"
    try_run gsettings set org.gnome.desktop.interface color-scheme "prefer-dark"
    try_run gsettings set org.gnome.desktop.interface icon-theme "kora"
    try_run gsettings set org.gnome.desktop.interface cursor-theme "Bibata-Modern-Ice"
    try_run gsettings set org.gnome.desktop.interface font-name "Adwaita Sans 11"
}

set_shell() {
    (( DO_SHELL )) || { item "fish не включён: ./install.sh --shell"; return 0; }

    local fish_bin
    fish_bin="$(command -v fish || true)"
    [[ -n "$fish_bin" ]] || { warn "fish не найден"; return 0; }

    run_loud chsh -s "$fish_bin" "$USER"
    ok "шелл по умолчанию: $fish_bin"
}

finish() {
    step "Финальные штрихи"
    apply_theme
    set_shell

    local inner=50
    local lines=(
        "Configs     $HOME/.config"
        "Wallpapers  $WALLPAPER_DIR"
    )
    (( BACKED_UP > 0 )) && lines+=("Backup      ~/${BACKUP#"$HOME"/}")

    local line
    for line in "${lines[@]}"; do
        (( ${#line} > inner )) && inner=${#line}
    done

    local border
    border="$(printf '─%.0s' $(seq 1 $((inner + 2))))"

    local title="Установка завершена"
    (( DRY_RUN )) && title="Проверка завершена — изменений нет"

    printf '\n  %s✓%s %s%s%s  %s(%ds)%s\n\n' \
        "$GREEN" "$R" "$B" "$title" "$R" \
        "$GREY" "$((SECONDS - START_TIME))" "$R"

    printf '%s╭%s%s╮%s%s\n' "$PURPLE" "$R" "$border" "$PURPLE" "$R"
    for line in "${lines[@]}"; do
        printf '%s│%s %-*s %s│%s\n' "$PURPLE" "$R" "$inner" "$line" "$PURPLE" "$R"
    done
    printf '%s╰%s%s╯%s%s\n' "$PURPLE" "$R" "$border" "$PURPLE" "$R"

    printf '\n   %s%s%s  %s·%s  %sСпасибо, что заглянул%s\n\n' \
        "$PINK" "$BRAND" "$R" "$GREY" "$R" "$GREY" "$R"

    if (( DRY_RUN )); then
        printf '   %sЭто был --dry-run. Запусти без флага, чтобы применить.%s\n\n' "$D" "$R"
    else
        printf '   %sПерелогинься в Hyprland (или перезапусти serpantinumd).%s\n' "$D" "$R"
        if (( BACKED_UP > 0 )); then
            printf '   %sСтарые файлы: %s%s\n' "$D" "$BACKUP" "$R"
        fi
        printf '\n'
    fi
}

# ─── main ────────────────────────────────────────────────────────────────────

intro

if [[ -t 0 && -t 1 ]] && (( ! ASSUME_YES && ! NO_INTRO )); then
    read -r _
fi

header

(( EUID == 0 )) && die "Не запускай установщик от root. sudo он попросит сам, если нужно."
command -v rsync >/dev/null 2>&1 || warn "rsync не найден, буду копировать через cp."

install_configs
install_home
install_bin
install_wallpapers

if (( DO_PACKAGES || DO_AUR || DO_FLATPAK )); then
    install_all_packages
fi

install_serpantinum
finish
