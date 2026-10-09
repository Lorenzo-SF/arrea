#!/usr/bin/env bash
# :: arrea.d/arrea.sh — instalador y verificador de arrea (CLI escript)
# ::
# :: Contrato de zaguan: --install / --check / --help.
# ::
# ::   bash arrea.d/arrea.sh --install   compila y enlaza ~/.local/bin/arrea
# ::   bash arrea.d/arrea.sh --check     verifica sin tocar nada
# ::   bash arrea.d/arrea.sh --help      esta ayuda
# ::
# :: Códigos de salida: 0 ok · 1 fallo · 2 opción desconocida · 3 falta herramienta
# ::
# :: Este script NO instala Erlang ni Elixir: comprueba que estén y, si faltan,
# :: dice qué ejecutar. Instalar un toolchain desde el script de otra tool es la
# :: forma de que nadie entienda por qué su máquina ha cambiado.

set -uo pipefail

# -----------------------------------------------------------------------------
# Resolver el path REAL de este script, atravesando symlinks.
#
# No es un detalle: el script se invoca como `bash arrea.d/arrea.sh`, pero si
# algún día se enlaza desde ~/.local/bin, `dirname` daría ~/.local/bin y REPO
# saldría como ~/.local. Que es exactamente el fallo que no se diagnostica.
#
# `readlink -f` no es portable (BSD no lo tiene). Un bucle de `readlink` sí.
# -----------------------------------------------------------------------------
_resolve_self() {
    local src="${BASH_SOURCE[0]}" dir
    while [[ -L "$src" ]]; do
        dir="$(cd -P "$(dirname "$src")" && pwd)"
        src="$(readlink "$src")"
        [[ "$src" != /* ]] && src="$dir/$src"
    done
    cd -P "$(dirname "$src")" && pwd
}

HERE="$(_resolve_self)"
SELF="$HERE/$(basename "${BASH_SOURCE[0]}")"
NAME="arrea"
# REPO es el padre del .d: <repo>/<name>.d/<name>.sh → <repo>
REPO="${ARREA_REPO:-$(cd "$HERE/.." && pwd)}"
BIN_DIR="${ARREA_BIN_DIR:-$HOME/.local/bin}"

# ── salida ───────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; B=$'\033[34m'; D=$'\033[2m'; N=$'\033[0m'
else
    R=''; G=''; Y=''; B=''; D=''; N=''
fi

ok()   { printf '%s✓%s %s\n' "$G" "$N" "$*"; }
warn() { printf '%s!%s %s\n' "$Y" "$N" "$*"; }
err()  { printf '%s✗%s %s\n' "$R" "$N" "$*" >&2; }
info() { printf '%s·%s %s\n' "$D" "$N" "$*"; }
step() { printf '\n%s== %s ==%s\n' "$B" "$*" "$N"; }

# -----------------------------------------------------------------------------
# Preflight: mix tiene que existir.
#
# Los shims de asdf van al PATH si faltan: sin ellos, `mix` no resuelve aunque
# Erlang y Elixir estén instalados, y el fallo dice "command not found", que
# apunta al sitio equivocado.
# -----------------------------------------------------------------------------
preflight() {
    case ":$PATH:" in
        *":$HOME/.asdf/shims:"*) ;;
        *)
            if [[ -d "$HOME/.asdf/shims" ]]; then
                info "shims de asdf no estaban en el PATH; se añaden para esta ejecución"
                PATH="$HOME/.asdf/shims:$PATH"
            fi
            ;;
    esac

    if ! command -v mix >/dev/null 2>&1; then
        err "mix no está instalado: $NAME no se puede compilar"
        printf '  %s\n' "solución (asdf):"
        printf '    %s\n' "git clone https://github.com/asdf-vm/asdf.git ~/.asdf"
        printf '    %s\n' "source ~/.asdf/asdf.sh   &&   asdf plugin add elixir"
        printf '    %s\n' "cd $REPO && asdf install"
        printf '  %s\n' "solución (Homebrew, macOS):"
        printf '    %s\n' "brew install erlang elixir"
        return 1
    fi

    return 0
}

# El repo tiene que ser un proyecto mix. No es "falta herramienta": es que este
# .sh no está donde debería, y eso es un fallo, no un préstamo.
check_project() {
    if [[ -f "$REPO/mix.exs" ]]; then
        return 0
    fi
    err "no hay mix.exs en $REPO"
    info "  ¿está $NAME.d en su sitio dentro del repo?"
    return 1
}

# Corre mix en silencio y, si falla, saca las últimas 20 líneas.
#
# Veinte, no todas: la traza de compilación de Elixir entera son cientos de
# líneas y el error útil ("undefined function", "could not find dependency")
# está siempre al final.
run_mix() {
    local out rc
    out=$(cd "$REPO" && "$@" 2>&1)
    rc=$?
    if (( rc != 0 )); then
        printf '%s\n' "$out" | tail -20 >&2
    fi
    return $rc
}

# Dónde está el ejecutable. Preferente la raíz del repo (donde lo deja batamanta
# y donde lo busca el alias `install` de mix.exs); si no, se busca en _build.
find_executable() {
    local cand
    for cand in "$REPO/$NAME" \
                "$REPO/_build/$NAME" \
                "$REPO/_build/prod/$NAME" \
                "$REPO/_build/dev/$NAME"; do
        [[ -f "$cand" ]] && { echo "$cand"; return 0; }
    done

    local found
    found=$(find "$REPO/_build" -type f -name "$NAME" 2>/dev/null | head -1)
    [[ -n "$found" ]] && { echo "$found"; return 0; }
    return 1
}

# ── --install ────────────────────────────────────────────────────────────────
do_install() {
    step "Preflight"
    if ! preflight; then
        err ""
        err "No se continúa: $NAME necesita mix (Elixir) para compilarse."
        return 3
    fi
    check_project || return 1
    info "elixir $(elixir --version 2>/dev/null | tail -1 | sed 's/^Elixir //')"

    step "Compilación (MIX_ENV=prod mix gen)"
    info "compilando y generando el ejecutable de $NAME (puede tardar)…"
    if ! run_mix env MIX_ENV=prod mix gen; then
        err "mix gen falló"
        err "  revisa las últimas líneas de arriba; lo normal es una dependencia sin resolver"
        return 1
    fi

    local exec_path
    if ! exec_path=$(find_executable); then
        err "compilado, pero no encuentro el ejecutable de $NAME"
        err "  buscado en: $REPO/$NAME y bajo $REPO/_build/"
        return 1
    fi
    chmod +x "$exec_path" 2>/dev/null || true
    ok "ejecutable: $exec_path"

    step "Symlink"
    mkdir -p "$BIN_DIR"
    # -f: si el alias `install` de mix.exs dejó ahí una COPIA, se sustituye por
    # el symlink. El binario real vive en el repo; ~/.local/bin solo apunta.
    if ! ln -sfn "$exec_path" "$BIN_DIR/$NAME"; then
        err "no se pudo enlazar $BIN_DIR/$NAME"
        return 1
    fi
    ok "symlink $BIN_DIR/$NAME -> $exec_path"

    step "Verificación"
    do_check
}

# ── --check ──────────────────────────────────────────────────────────────────
do_check() {
    local fails=0

    step "Toolchain"
    if ! preflight; then
        err "$NAME no puede compilarse sin mix"
        return 3
    fi
    ok "mix $(mix --version 2>/dev/null | head -1)"

    step "Proyecto"
    if check_project; then
        ok "mix.exs encontrado ($REPO)"
    else
        fails=$((fails + 1))
    fi

    step "Compilación"
    if run_mix mix compile; then
        ok "compila"
    else
        err "mix compile falló"
        fails=$((fails + 1))
    fi

    step "Symlink"
    local link="$BIN_DIR/$NAME"
    if [[ -L "$link" || -e "$link" ]]; then
        if [[ -x "$link" ]]; then
            ok "$link apunta a $(readlink "$link" 2>/dev/null || echo "$link")"
        else
            err "$link existe pero no es ejecutable"
            fails=$((fails + 1))
        fi
    else
        err "no existe $link"
        info "  para crearlo: bash $SELF --install"
        fails=$((fails + 1))
    fi

    if [[ -x "$link" ]]; then
        step "Ejecución"
        if "$link" --version >/dev/null 2>&1; then
            ok "$NAME --version responde"
        elif "$link" --help >/dev/null 2>&1; then
            ok "$NAME --help responde (no tiene --version)"
        else
            err "$NAME no responde ni a --version ni a --help"
            fails=$((fails + 1))
        fi
    fi

    step "Resumen"
    if (( fails == 0 )); then
        ok "$NAME está correctamente instalado"
        return 0
    fi
    err "$fails comprobación(es) fallida(s)"
    return 1
}

usage() {
    cat <<EOF
$NAME — CLI escript

  Es un ejecutable de línea de comandos generado con mix/batamanta a partir
  de este repo. Este script lo compila y lo enlaza en ~/.local/bin.

USO:
  bash $SELF --install   compila (MIX_ENV=prod mix gen) y enlaza ~/.local/bin/$NAME
  bash $SELF --check     verifica sin tocar nada
  bash $SELF --help      esta ayuda

VARIABLES DE ENTORNO:
  ARREA_REPO        raíz del repo (default: padre de este .d)
  ARREA_BIN_DIR     destino del symlink (default: ~/.local/bin)

CÓDIGOS DE SALIDA:
  0  ok
  1  fallo (compilación, ejecutable ausente o symlink roto)
  2  opción desconocida
  3  falta herramienta (mix / Elixir no están)
EOF
}

case "${1:-}" in
    --install) do_install ;;
    --check)   do_check ;;
    --help|-h) usage ;;
    *)
        err "opción desconocida: ${1:-<ninguna>}"
        usage
        exit 2
        ;;
esac
