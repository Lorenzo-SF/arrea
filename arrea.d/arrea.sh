#!/usr/bin/env bash
# :: :: :: :: :: :: :: :: :: :: :: :: :: :: :: :: :: :: :: :: :: :: :: :: :: ::
# ::  arrea — instalador y verificador del CLI Elixir (escript)
# ::
# ::  Contrato de lasaca:
# ::    arrea.sh --install   compila/empaqueta (MIX_ENV=prod mix gen) y enlaza
# ::    arrea.sh --check     verifica sin reinstalar
# ::    arrea.sh --help      esta ayuda
# ::
# ::  arrea es un ESCRIPT Elixir (mix.exs: `escript: [main_module: arrea]`), NO un
# ::  daemon. Aquí no hay --start/--daemon/--stop, ni launchd/plist, ni release
# ::  de Phoenix. Este script sólo: (1) exige que `mix` exista y arranque,
# ::  (2) ejecuta `mix gen` para limpiar/traer deps/compilar/empaquetar, y
# ::  (3) deja un symlink `arrea` en ~/.local/bin (o $arrea_BIN_DIR).
# :: :: :: :: :: :: :: :: :: :: :: :: :: :: :: :: :: :: :: :: :: :: :: :: :: ::
set -uo pipefail

# No colgarse pidiendo credenciales por terminal.
#
# `mix gen` encadena `deps.get`, y las dependencias propias (alaja, arrea,
# apero, de Lorenzo-SF/*) son repos PRIVADOS. Si git intentara preguntar
# usuario/contraseña (o confirmar la clave del host) se quedaría esperando para
# siempre. Con esto el fallo es inmediato y se reporta (ver hint en do_install).
export GIT_TERMINAL_PROMPT=0
export GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=10"

# Resolver el path REAL de este script, atravesando symlinks.
#
# No es un detalle: el script se invoca como ~/.local/bin/arrea, que es un
# symlink a él. Sin resolver, `dirname` da ~/.local/bin, REPO sale como ~/.local
# y todo falla apuntando al sitio equivocado. `readlink -f` no es portable
# (BSD/macOS no lo tiene); un bucle de `readlink` sí.
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
REPO="${arrea_REPO:-$(cd "$HERE/.." && pwd)}"
EXE="$REPO/arrea"
BIN_DIR="${arrea_BIN_DIR:-$HOME/.local/bin}"

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


require_mix() {
    if ! command -v mix >/dev/null 2>&1 && [[ -d "$HOME/.asdf/shims" ]]; then
        PATH="$HOME/.asdf/shims:$PATH"; export PATH
        info "mix no estaba en el PATH; se añade ~/.asdf/shims"
    fi
    if ! command -v mix >/dev/null 2>&1; then
        err "no encuentro \`mix\` en el PATH"
        printf '  %s\n' "arrea se compila con Elixir/mix. Instálalos, p. ej.:"
        printf '  %s\n' "  · asdf:  cd \"$REPO\" && asdf install   (usa .tool-versions)"
        printf '  %s\n' "  · brew:  brew install erlang elixir"
        return 1
    fi
    if ! mix --version >/dev/null 2>&1; then
        err "\`mix\` no arranca: falta la versión de Erlang/Elixir del proyecto"
        printf '  %s\n' "  cd \"$REPO\" && asdf install   # instala lo de .tool-versions"
        return 1
    fi
    info "$(mix --version 2>/dev/null | head -1)"
    return 0
}
 
 # raíz del repo; si no está (build antiguo u otro layout), buscamos en _build.
find_arrea_exe() {
    local cand="$REPO/arrea" found
    [[ -f "$cand" ]] && { printf '%s\n' "$cand"; return 0; }
    [[ -d "$REPO/_build" ]] || return 1
    found="$(find "$REPO/_build" -type f -name arrea 2>/dev/null | head -1)"
    [[ -n "$found" ]] && { printf '%s\n' "$found"; return 0; }
    return 1
}

# ── --install ────────────────────────────────────────────────────────────────
do_install() {
    step "Preflight"
    require_mix || return 3

    step "Compilar y empaquetar (MIX_ENV=prod mix gen)"
    info "en $REPO: clean_build · deps.get · compile · batamanta. Puede tardar…"
    local log rc
    
    asdf set elixir 1.19.5-otp-28
    asdf set erlang 28.5.0.7 

    (cd "$REPO" && MIX_ENV=prod mix gen 2>&1) && ok "Compilado y empaquetado" || error "Hubo problemas al compilar"

    step "Localizar ejecutable"
    local exe
    if ! exe="$(find_arrea_exe)"; then
        err "no encuentro el ejecutable \`arrea\`"
        printf '  %s\n' "buscado en: $REPO/arrea y $REPO/_build/**/arrea"
        return 1
    fi

    ok "$EXE"

    step "Enlazar en $BIN_DIR"
    chmod +x "$EXE" 2>/dev/null || true
    mkdir -p "$BIN_DIR"
    ln -sfn "$EXE" "$BIN_DIR/arrea" && ok "$BIN_DIR/arrea -> $EXE" || error "No se hizo el symlink correctamente"
    
    return 0
}

# ── --check ──────────────────────────────────────────────────────────────────
do_check() {
    local fails=0

    step "Toolchain"
    require_mix || return 3

    step "Compilar"
    local log rc
    log="$(cd "$REPO" && mix deps.get && mix compile 2>&1)"; rc=$?
    if (( rc == 0 )); then
        ok "mix compile OK"
    else
        err "\`mix compile\` falló (exit $rc)"
        printf '%s\n' "$log" | tail -20 | sed 's/^/    /'
        fails=$((fails + 1))
    fi

    step "Symlink"
    local link="$BIN_DIR/arrea"
    if [[ -L "$link" ]]; then
        if [[ -x "$link" ]]; then
            ok "$link -> $(readlink "$link")"
        else
            err "$link es symlink pero no resuelve a un ejecutable"
            fails=$((fails + 1))
        fi
    else
        err "no hay symlink en $link (¿falta \`arrea.sh --install\`?)"
        fails=$((fails + 1))
    fi

    step "Ejecución"
    if [[ -x "$link" ]]; then
        if smoke_arrea "$link"; then
            ok "arrea --version/--help responde (exit 0)"
        else
            err "arrea no responde a --version ni a --help"
            fails=$((fails + 1))
        fi
    fi

    step "Resumen"
    if (( fails == 0 )); then
        ok "arrea está correctamente instalado"
        return 0
    fi
    err "$fails comprobación(es) fallida(s)"
    return 1
}

usage() {
    cat <<'EOF'
arrea — CLI Elixir (escript) para declarar y ejecutar peticiones HTTP

  arrea.sh --install    Compila y empaqueta (MIX_ENV=prod mix gen) y deja un
                       symlink `arrea` en ~/.local/bin. Idempotente.
  arrea.sh --check      Verifica sin reinstalar: toolchain, mix compile, symlink
                       y que el binario responda a --version/--help.
  arrea.sh --help       Esta ayuda.

  arrea_BIN_DIR   Directorio del symlink (default ~/.local/bin).
  arrea_REPO      Raíz del repo arrea (default: directorio padre de arrea.d).

Códigos de salida: 0 ok · 1 fallo · 2 opción desconocida · 3 falta mix.
EOF
}

case "${1:-}" in
    --install|-i) do_install; exit $? ;;
    --check)      do_check;   exit $? ;;
    --help|-h|"") usage;      exit 0 ;;
    *)            err "opción desconocida: $1"; usage; exit 2 ;;
esac
