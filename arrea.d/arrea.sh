#!/usr/bin/env bash
# :: :: :: :: :: :: :: :: :: :: :: :: :: :: :: :: :: :: :: :: :: :: :: :: :: ::
# ::  arrea — Asynchronous process orchestrator (OTP) and telemetry
# ::
# ::  Contrato de instalación de los meta-repos (lasaca / zaguan):
# ::    arrea.sh --install   prepara el entorno, compila y deja el proyecto listo
# ::    arrea.sh --check     verifica SIN instalar nada (no muta el repo)
# ::    arrea.sh --help      esta ayuda
# ::
# ::  Implementa el mismo contrato que el resto de proyectos, con la misma
# ::  salida: [✓] ok · [!] aviso · [✗] fallo · [-] omitido.
# ::
# ::  ## Toolchain: asdf NO se instala aquí
# ::
# ::  Este script nunca instala asdf ni los SDK que gestiona. Solo comprueba que
# ::  estén disponibles y, si lo están, fija las versiones de `.tool-versions`
# ::  con `asdf set` para que `mix` use SIEMPRE las del proyecto. Instalar un
# ::  toolchain es de `setup`, no de cada repo: si lo hiciera cada repo, N
# ::  installs competirían por el mismo estado global de asdf.
# ::
# ::  Si no hay asdf pero sí `mix` (brew, apt, Elixir del sistema), se sigue
# ::  adelante: las versiones las pone quien gestiona ese Erlang/Elixir.
# :: :: :: :: :: :: :: :: :: :: :: :: :: :: :: :: :: :: :: :: :: :: :: :: :: :: ::
set -uo pipefail

# `deps.get` encadena git contra repos PRIVADOS. Si gitDvise a preguntar
# usuario/contraseña se queda esperando para siempre, y el instalador parece
# colgado en lugar de fallar.
export GIT_TERMINAL_PROMPT=0
export GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=10"

# ── identidad ────────────────────────────────────────────────────────────────
# El nombre sale del propio script, no de una constante repetida: una copia
# mal renombrada (`acoh.sh`) follows symlink y reportaría el nombre ajeno.
NAME="$(basename "${BASH_SOURCE[0]}" .sh)"
PROJECT="arrea"
DESC="Asynchronous process orchestrator (OTP) and telemetry"
REPO="${ARREA_REPO:-}"
BIN_DIR="${ARREA_BIN_DIR:-$HOME/.local/bin}"

# ── salida (idéntica en todos los proyectos) ─────────────────────────────────
if [[ -t 1 ]]; then
    _R=$'\033[31m'; _G=$'\033[32m'; _Y=$'\033[33m'; _B=$'\033[34m'; _D=$'\033[2m'; _N=$'\033[0m'
else
    _R=''; _G=''; _Y=''; _B=''; _D=''; _N=''
fi

OKS=0; WARNS=0; FAILS=0
ok()   { printf '  %s[✓]%s %s\n' "$_G" "$_N" "$*"; OKS=$((OKS+1)); }
warn() { printf '  %s[!]%s %s\n' "$_Y" "$_N" "$*"; WARNS=$((WARNS+1)); }
fail() { printf '  %s[✗]%s %s\n' "$_R" "$_N" "$*"; FAILS=$((FAILS+1)); }
skip() { printf '  %s[-]%s %s\n' "$_D" "$_N" "$*"; }
info() { printf '      %s\n' "$*"; }
step() { printf '\n%s[%s] %s%s\n' "$_B" "$1" "$2" "$_N"; }
hint() { printf '      %s→ %s%s\n' "$_D" "$*" "$_N"; }

die_usage() { fail "opción desconocida: ${1:-}"; usage; exit 2; }

# ── repo ─────────────────────────────────────────────────────────────────────
# SCRIPT_DIR siguiendo symlinks: el script se invoca desde ~/.local/bin, y sin
# resolver `dirname` da ~/.local/bin, no el repo. `readlink -f` no es portable
# (BSD/macOS); un bucle de `readlink` sí.
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
[[ -z "$REPO" ]] && REPO="$(cd "$HERE/.." && pwd)"

# ── toolchain ────────────────────────────────────────────────────────────────
# `.tool-versions` es la ÚNICA fuente de versiones. Nada de `asdf set` con
# versiones escritas a mano en el script: envejecierían por separado del repo y
# el fallo aparecería como "compila con una versión y no con la otra".
tv_plugin_version() {
    local plugin="$1"
    [[ -f "$REPO/.tool-versions" ]] || return 1
    # Ignora comentarios y líneas en blanco; `asdf set` no los entiende.
    sed -n -E "s/^[[:space:]]*${plugin}[[:space:]]+([^[:space:]#]+).*/\1/p" \
        "$REPO/.tool-versions" | head -1
}

# `tv_plugins` lista los plugins declarados en .tool-versions.
#
# Se recorre el FICHERO en vez de tener una lista fija (erlang, elixir): esa
# lista se queda corta en cuanto un repo declara otro toolchain. posadero
# declara también golang, y con la lista fija ese SDK no se fijaba nunca — el
# --install informaba "toolchain OK" sin haber mirado la mitad de lo que el
# repo necesita. Además, el orden de `asdf set` importa (golang antes que
# elixir puede decidir qué toolchain se compila), así que se va en el orden
# en que los declara el repo, no en uno alfabético inventado aquí.
tv_plugins() {
    [[ -f "$REPO/.tool-versions" ]] || return 1
    # Se ignoran comentarios y líneas en blanco: `asdf set` no los entiende y
    # un "# Candil 4.0 ..." de cabecera no es un plugin.
    sed -n -E 's/^[[:space:]]*([A-Za-z0-9_.-]+)[[:space:]]+([^[:space:]#]+).*/\1/p' \
        "$REPO/.tool-versions" | awk '!seen[$0]++'
}

pin_toolchain() {
    local asdf_cmd="" p v pinned=0
    if command -v asdf >/dev/null 2>&1; then
        asdf_cmd="asdf"
    elif [[ -x "$HOME/.asdf/bin/asdf" ]]; then
        asdf_cmd="$HOME/.asdf/bin/asdf"
        PATH="$HOME/.asdf/bin:$PATH"; export PATH
    fi

    if [[ -n "$asdf_cmd" ]]; then
        # `asdf set` escribe en .tool-versions local. Se ejecuta en el repo con
        # las versiones YA leídas de ahí, así que es idempotente por
        # construcción: no puede introducir una versión que el repo no tenga.
        while read -r p; do
            [[ -n "$p" ]] || continue
            v="$(tv_plugin_version "$p")" || continue
            [[ -n "$v" ]] || continue
            if (cd "$REPO" && "$asdf_cmd" set "$p" "$v" >/dev/null 2>&1); then
                ok "$p $v (asdf set)"
                pinned=$((pinned+1))
            else
                warn "asdf set $p $v falló"
                hint "comprueba que el plugin esté instalado: asdf plugin list"
            fi
        done < <(tv_plugins)
        (( pinned == 0 )) && skip "sin plugins en .tool-versions que fijar"
        return 0
    fi

    # Sin asdf: no es un fallo si hay un Erlang/Elixir del sistema. Solo es un
    # fallo si NO hay mix, que es lo que se comprueba en require_mix.
    skip "asdf no está instalado; se usa el Erlang/Elixir del PATH"
    hint "gestiona el toolchain con: setup  ·  o instala asdf y ejecuta: asdf install"
}

require_mix() {
    if ! command -v mix >/dev/null 2>&1 && [[ -d "$HOME/.asdf/shims" ]]; then
        PATH="$HOME/.asdf/shims:$PATH"; export PATH
        ok "shims de asdf añadidos al PATH"
    fi
    if ! command -v mix >/dev/null 2>&1; then
        fail "no encuentro \`mix\` en el PATH"
        hint "asdf:  cd \"$REPO\" && asdf install     # lee .tool-versions"
        hint "brew:  brew install erlang elixir"
        return 1
    fi
    if ! mix --version >/dev/null 2>&1; then
        fail "\`mix\` no arranca: falta la versión de Erlang/Elixir del proyecto"
        hint "cd \"$REPO\" && asdf install"
        return 1
    fi
    ok "$(mix --version 2>/dev/null | head -1)"
    return 0
}

# ── ejecutable (solo proyectos escript) ──────────────────────────────────────
# Un escript deja el binario en la raíz del repo. Se busca también en _build
# porque un build antiguo puede tener otro layout.
find_exe() {
    local cand="$REPO/$PROJECT" found
    [[ -f "$cand" ]] && { printf '%s\n' "$cand"; return 0; }
    [[ -d "$REPO/_build" ]] || return 1
    found="$(find "$REPO/_build" -type f -name "$PROJECT" 2>/dev/null | head -1)"
    [[ -n "$found" ]] && { printf '%s\n' "$found"; return 0; }
    return 1
}

# ── fases de --install ───────────────────────────────────────────────────────
phase_toolchain() {
    pin_toolchain
    require_mix || return 3
}

phase_deps() {
    if (cd "$REPO" && mix deps.get >/tmp/${PROJECT}_deps.$$ 2>&1); then
        ok "dependencias resueltas"
        return 0
    fi
    fail "mix deps.get falló"
    tail -20 /tmp/${PROJECT}_deps.$$ | sed 's/^/      /'
    hint "las deps de Lorenzo-SF/* son privadas: necesitas clave SSH de GitHub"
    rm -f /tmp/${PROJECT}_deps.$$
    return 1
}

phase_build() {
    # `mix gen` es el alias del proyecto (clean_build · deps.get · compile ·
    # batamanta). Reconstruye desde cero, que es lo que hace falta después de
    # un formateo o de un cambio de versión de Elixir.
    if (cd "$REPO" && MIX_ENV=prod mix gen >/tmp/${PROJECT}_build.$$ 2>&1); then
        ok "MIX_ENV=prod mix gen OK"
        rm -f /tmp/${PROJECT}_build.$$
    else
        rc=$?
        fail "MIX_ENV=prod mix gen falló (rc=$rc)"
        tail -25 /tmp/${PROJECT}_build.$$ | sed 's/^/      /'
        rm -f /tmp/${PROJECT}_build.$$
        hint "repite con: cd \"$REPO\" && MIX_ENV=prod mix gen"
        return 1
    fi
}

phase_link() {
    local exe
    if ! exe="$(find_exe)"; then
        fail "no encuentro el ejecutable \`$PROJECT\`"
        hint "buscado en: $REPO/$PROJECT y $REPO/_build/**/$PROJECT"
        return 1
    fi
    ok "ejecutable: $exe"

    chmod +x "$exe" 2>/dev/null || true
    mkdir -p "$BIN_DIR" || { fail "no se pudo crear $BIN_DIR"; return 1; }

    # `ln -sfn` no sustituye un fichero REAL que ya ocupe el destino (candil
    # deja uno: su alias `mix gen install` copia en vez de enlazar), y `ln -sf`
    # sobre un symlink a directorio se mete dentro. Por eso el `rm` previo:
    # se quita lo que haya y se enlaza limpio.
    rm -f "$BIN_DIR/$PROJECT"
    if ln -s "$exe" "$BIN_DIR/$PROJECT"; then
        ok "$BIN_DIR/$PROJECT -> $exe"
    else
        fail "no se pudo crear el symlink en $BIN_DIR"
        return 1
    fi

    if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
        warn "$BIN_DIR NO está en el PATH"
        hint 'export PATH="$HOME/.local/bin:$PATH"'
    fi
}

phase_verify() {
    if (cd "$REPO" && mix compile >/dev/null 2>&1); then
        ok "el proyecto compila"
    else
        fail "mix compile falló"
        hint "mira el error con: cd \"$REPO\" && mix compile"
    fi
}

# ── --install ────────────────────────────────────────────────────────────────
do_install() {
    OKS=0; WARNS=0; FAILS=0
    printf '\n%s══ %s --install ══%s\n' "$_B" "$PROJECT" "$_N"

    local n=0
    local INSTALL_PHASES=5
    n=$((n+1)); step "$n/$INSTALL_PHASES" "Toolchain";    phase_toolchain || return $?
    n=$((n+1)); step "$n/$INSTALL_PHASES" "Dependencias"; phase_deps    || true
    n=$((n+1)); step "$n/$INSTALL_PHASES" "Compilación";  phase_build   || true
    n=$((n+1)); step "$n/$INSTALL_PHASES" "Symlink";   phase_link    || true
    n=$((n+1)); step "$n/$INSTALL_PHASES" "Verificación"; phase_verify  || true

    printf '\n%s── Resumen ──%s\n' "$_B" "$_N"
    printf '  %s ok · %s avisos · %s fallos\n' "$OKS" "$WARNS" "$FAILS"
    printf '  Binario:    %s/%s\n' "$BIN_DIR" "$PROJECT"
    printf '  Repo:       %s\n' "$REPO"
    printf '\n'
    if (( FAILS > 0 )); then
        printf '%sInstalación incompleta.%s Diagnóstico: %s --check\n' "$_R" "$_N" "$PROJECT"
        return 1
    fi
    printf '%sInstalación completa.%s Verifica con: %s --check\n' "$_G" "$_N" "$PROJECT"
    return 0
}

# ── --check ──────────────────────────────────────────────────────────────────
# NO instala: no hace `deps.get`, no crea symlinks, no instala asdf ni SDK.
# `mix compile` SÍ se ejecuta, y eso escribe en `_build` cuando está
# desactualizado. Se dice explícitamente en el `--help` en vez de prometer que
# "no escribe nada": una promesa que miente es peor que una limitación
# documentada, porque hace que alguien confíe en un check que sí toca el disco.
#
# Es lo que hace falta para responder a la pregunta del contrato ("¿está todo
# lo que necesita instalado?"), y `mix compile` no baja dependencias: si faltan
# dice que falten, en vez de resolverlas por su cuenta como hace `deps.get`.
do_check() {
    OKS=0; WARNS=0; FAILS=0
    printf '\n%s== %s --check ==%s\n\n' "$_B" "$PROJECT" "$_N"

    step "1/4" "Toolchain"
    if command -v asdf >/dev/null 2>&1 || [[ -x "$HOME/.asdf/bin/asdf" ]]; then
        ok "asdf disponible"
        local p v
        while read -r p; do
            [[ -n "$p" ]] || continue
            v="$(tv_plugin_version "$p")" || continue
            [[ -n "$v" ]] || continue
            if (cd "$REPO" && asdf current "$p" 2>/dev/null | grep -q "$v"); then
                ok "$p $v activo"
            else
                warn "$p: .tool-versions pide $v pero no es la versión activa"
                hint "asdf set $p $v   ·   o: asdf install"
            fi
        done < <(tv_plugins)
    else
        warn "asdf no instalado (opcional si mix funciona)"
    fi
    require_mix || true

    step "2/4" "Compilación"
    # `mix compile --warnings-as-errors` NO: un aviso de dependencia no es un
    # fallo de instalación. Se usa `mix compile`, que es idempotente y rápido
    # cuando ya está compilado.
    if (cd "$REPO" && mix compile >/dev/null 2>&1); then
        ok "el proyecto compila"
    else
        warn "mix compile devolvió error"
        hint "cd \"$REPO\" && mix compile"
    fi
    if [[ -d "$REPO/_build" ]]; then
        ok "_build presente"
    else
        warn "_build ausente: nunca se compiló aquí"
    fi

    step "3/4" "Symlink"
    local exe link
    if exe="$(find_exe)"; then
        ok "ejecutable: $exe"
        if [[ -x "$exe" ]]; then
            ok "es ejecutable"
        else
            fail "no es ejecutable"
            hint "chmod +x $exe"
        fi
    else
        fail "no hay ejecutable compilado"
        hint "$PROJECT --install"
    fi

    link="$BIN_DIR/$PROJECT"
    if [[ -L "$link" && -x "$link" ]]; then
        ok "$PROJECT -> $(readlink "$link")"
        if "$link" --version >/dev/null 2>&1 || "$link" version >/dev/null 2>&1 \
           || "$link" --help >/dev/null 2>&1; then
            ok "el binario responde"
        else
            warn "el binario no responde a --version/version/--help"
            hint "$link --help"
        fi
    elif [[ -e "$link" ]]; then
        warn "$link es un fichero real, no un symlink"
        hint "$PROJECT --install   # lo reemplaza por un symlink"
    else
        fail "no hay symlink en $link"
        hint "$PROJECT --install"
    fi

    if [[ ":$PATH:" == *":$BIN_DIR:"* ]]; then
        ok "$BIN_DIR en el PATH"
    else
        warn "$BIN_DIR NO está en el PATH"
    fi
    step "4/4" "Resumen"
    printf '  %s ok · %s avisos · %s fallos\n\n' "$OKS" "$WARNS" "$FAILS"
    if (( FAILS > 0 )); then
        printf '  %s[✗] %s --check FALLÓ → ejecuta: %s --install%s\n\n' "$_R" "$PROJECT" "$PROJECT" "$_N"
        return 1
    fi
    printf '  %s[✓] %s --check OK%s\n\n' "$_G" "$PROJECT" "$_N"
    return 0
}

# ── --help ───────────────────────────────────────────────────────────────────
usage() {
    cat <<HELP
$PROJECT — $DESC

${_B}USO${_N}
  $SCRIPT_NAME --install    prepara el toolchain, compila y deja el proyecto listo
  $SCRIPT_NAME --check      verifica SIN instalar ni modificar nada
  $SCRIPT_NAME --help       esta ayuda

${_B}QUÉ HACE --install${_N}
  1. Toolchain    comprueba que hay Erlang/Elixir y, si asdf está instalado,
                  hace \`asdf set\` con las versiones de .tool-versions.
                  NO instala asdf ni SDK: eso es de \`setup\`.
  2. Dependencias mix deps.get
  3. Compilación  MIX_ENV=prod mix gen (clean_build · deps.get · compile · batamanta)
  4. Symlink
                  symlink en ~/.local/bin hacia el escript compilado
  5. Verificación compila de nuevo y comprueba que nada quedó a medias

${_B}QUÉ HACE --check${_N}
  Verifica toolchain, compilación y enlaces. NO instala nada: no hace
  deps.get, no crea symlinks, no instala asdf ni SDK.

  Sí ejecuta \`mix compile\`, así que puede escribir en _build si está
  desactualizado. Es deliberado: es lo que responde a "¿esto compila?". Si
  faltan dependencias, mix lo dice; no las baja por su cuenta.

  Sale 1 si falta algo.

${_B}VARIABLES${_N}
  ARREA_REPO      raíz del repo (por defecto: el directorio padre de este script)
  ARREA_BIN_DIR   dónde se crean los enlaces (por defecto ~/.local/bin)

${_B}CÓDIGOS DE SALIDA${_N}
  0 ok · 1 fallo · 2 opción desconocida
HELP
}

SCRIPT_NAME="$PROJECT.d/$NAME.sh"

case "${1:-}" in
    --install|-i) do_install; exit $? ;;
    --check)      do_check;   exit $? ;;
    --help|-h|help|"") usage; exit 0 ;;
    *)            die_usage "$1" ;;
esac