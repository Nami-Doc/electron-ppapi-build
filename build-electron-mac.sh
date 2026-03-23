#!/bin/bash
set -e

# ============================================================
#  Build Electron macOS avec PPAPI Flash
#
#  Usage :
#    ./build-electron-mac.sh           → build pour l'arch native
#    ./build-electron-mac.sh arm64     → forcer arm64
#    ./build-electron-mac.sh x64       → forcer x64 (cross-compile)
#    ./build-electron-mac.sh both      → build arm64 puis x64
#
#  Prérequis : ~100 Go d'espace libre, connexion internet
#  Durée totale : 3-6 heures par build
#  Le résultat sera sur le Bureau : Electron-mac-ARCH.tar.gz
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ELECTRON_COMMIT="a2da68124557f306c6f9b0011e74f72884aa4206"
BUILD_DIR="$HOME/electron-build"
PATCH_REPO="https://github.com/Nami-Doc/electron-ppapi-build/raw/main"

echo ""
echo "========================================"
echo "  Electron macOS — Build PPAPI Flash"
echo "========================================"
echo ""

# ── Mode double build ──
if [ "$1" = "both" ]; then
    echo "[INFO] Mode double build : arm64 puis x64"
    echo ""
    "$0" arm64
    echo ""
    echo "========================================"
    echo "  Lancement du 2e build (x64)..."
    echo "========================================"
    echo ""
    "$0" x64
    exit 0
fi

# ── Architecture cible ──
if [ -n "$1" ]; then
    TARGET_CPU="$1"
    echo "[INFO] Architecture forcée → $TARGET_CPU"
else
    ARCH=$(uname -m)
    if [ "$ARCH" = "arm64" ]; then
        TARGET_CPU="arm64"
    else
        TARGET_CPU="x64"
    fi
    echo "[INFO] Architecture détectée → $TARGET_CPU"
fi
echo ""

# ── Vérifier qu'on est sur macOS ──
if [ "$(uname -s)" != "Darwin" ]; then
    echo "[ERREUR] Ce script doit être exécuté sur macOS."
    exit 1
fi

# ── Vérifier l'espace disque ──
FREE_GB=$(df -g / | tail -1 | awk '{print $4}')
echo "[INFO] Espace libre : ${FREE_GB} Go"
if [ "$FREE_GB" -lt 50 ]; then
    echo "[ERREUR] Moins de 50 Go libres. La compilation nécessite ~80-100 Go."
    echo "         Libère de l'espace et relance le script."
    exit 1
elif [ "$FREE_GB" -lt 80 ]; then
    echo "[ATTENTION] Moins de 80 Go libres, ça peut être juste."
fi
echo ""

# ══════════════════════════════════════════════════
#  PRÉREQUIS : Xcode, Git, Python
# ══════════════════════════════════════════════════

# ── Demander le mot de passe sudo une fois (cache 15 min) ──
echo "[INFO] Le script a besoin de sudo pour configurer Xcode."
sudo -v
# Rafraîchir le cache sudo en arrière-plan pendant le build
while true; do sudo -n true; sleep 120; kill -0 "$$" || exit; done 2>/dev/null &

# ── Xcode Command Line Tools ──
if ! xcode-select -p &>/dev/null; then
    echo "[INSTALL] Xcode Command Line Tools..."
    xcode-select --install 2>/dev/null || true
    echo "          Attente de la fin d'installation..."
    until xcode-select -p &>/dev/null; do
        sleep 10
    done
    echo "[OK] Xcode CLT installé"
fi

# ── Xcode complet (nécessaire pour les SDK) ──
if ! xcodebuild -version &>/dev/null; then
    echo "[INSTALL] Xcode complet requis pour les SDK macOS."
    # Essayer mas (Mac App Store CLI)
    if ! command -v mas &>/dev/null; then
        if ! command -v brew &>/dev/null; then
            echo "[INSTALL] Homebrew..."
            NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
            eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv 2>/dev/null)"
        fi
        echo "[INSTALL] mas (Mac App Store CLI)..."
        brew install mas
    fi
    echo "[INSTALL] Xcode via App Store (30-60 min)..."
    echo "          Ne ferme pas le Terminal !"
    mas install 497799835 || {
        echo "[ERREUR] Échec de l'installation automatique de Xcode."
        echo "         Installe Xcode manuellement depuis l'App Store puis relance."
        exit 1
    }
    until xcodebuild -version &>/dev/null; do
        sleep 30
    done
    sudo xcodebuild -license accept 2>/dev/null || true
    echo "[OK] Xcode installé"
fi

# ── Vérifier Xcode >= 16 (macOS 15 SDK avec kVK_ContextualMenu etc.) ──
XCODE_MAJOR=$(xcodebuild -version 2>/dev/null | head -1 | awk '{print $2}' | cut -d. -f1)
if [ -n "$XCODE_MAJOR" ] && [ "$XCODE_MAJOR" -lt 16 ] 2>/dev/null; then
    echo "[ERREUR] Xcode $XCODE_MAJOR détecté — Xcode 16+ requis."
    echo "         Mets à jour Xcode depuis l'App Store puis relance."
    exit 1
fi

# Sélectionner le Xcode le plus récent (non-Beta)
XCODE_APP=$(ls -d /Applications/Xcode*.app 2>/dev/null | grep -v Beta | sort -V | tail -1)
if [ -n "$XCODE_APP" ]; then
    sudo xcode-select -s "$XCODE_APP"
fi
echo "[OK] $(xcodebuild -version | head -1) — SDK $(xcrun --show-sdk-version)"

# ── Metal Toolchain (requis pour compiler ANGLE/Metal shaders) ──
# Xcode 26+ sépare le Metal Toolchain du bundle Xcode.
# Chromium hardcode les chemins vers XcodeDefault.xctoolchain/usr/bin/metal*.
# On installe le toolchain si absent, puis on symlinke tous les outils Metal.
if ! xcrun --find metal &>/dev/null; then
    echo "[INSTALL] Metal Toolchain..."
    sudo xcodebuild -downloadComponent MetalToolchain
    until xcrun --find metal &>/dev/null; do
        sleep 5
    done
    echo "[OK] Metal Toolchain installé"
fi

XCODE_BIN="$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain/usr/bin"
METAL_REAL=$(xcrun --find metal 2>/dev/null)
if [ -n "$METAL_REAL" ]; then
    METAL_DIR=$(dirname "$METAL_REAL")
    # Si metal n'est pas dans le répertoire Xcode attendu → symlinker
    if [ "$METAL_DIR" != "$XCODE_BIN" ] && [ -d "$XCODE_BIN" ]; then
        echo "[FIX] Metal Toolchain externe détecté (Xcode 26+), création des symlinks..."
        for tool in "$METAL_DIR"/metal*; do
            NAME=$(basename "$tool")
            if [ ! -e "$XCODE_BIN/$NAME" ] || [ -L "$XCODE_BIN/$NAME" ]; then
                sudo ln -sf "$tool" "$XCODE_BIN/$NAME"
            fi
        done
        echo "[OK] Outils Metal symlinkés dans $XCODE_BIN"
    fi
fi

# ── Git (vient avec Xcode CLT) ──
if ! command -v git &>/dev/null; then
    echo "[ERREUR] Git non trouvé. Installe Xcode CLT puis relance."
    exit 1
fi

# ── Python 3 ──
if ! command -v python3 &>/dev/null; then
    echo "[INSTALL] Python 3..."
    if ! command -v brew &>/dev/null; then
        NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv 2>/dev/null)"
    fi
    brew install python3
fi
echo "[OK] Python $(python3 --version | awk '{print $2}')"
echo ""

# ══════════════════════════════════════════════════
#  ÉTAPE 1 : depot_tools
# ══════════════════════════════════════════════════
if [ ! -d "$BUILD_DIR/depot_tools" ]; then
    echo "[ÉTAPE 1/8] Téléchargement de depot_tools..."
    mkdir -p "$BUILD_DIR"
    git clone --depth=1 https://chromium.googlesource.com/chromium/tools/depot_tools.git "$BUILD_DIR/depot_tools"
else
    echo "[ÉTAPE 1/8] depot_tools présent ✓"
fi
export PATH="$BUILD_DIR/depot_tools:$PATH"
echo ""

# ══════════════════════════════════════════════════
#  ÉTAPE 2 : configurer gclient
# ══════════════════════════════════════════════════
echo "[ÉTAPE 2/8] Configuration de gclient..."
mkdir -p "$BUILD_DIR"
cat > "$BUILD_DIR/.gclient" << EOF
solutions = [
  {
    "name": "src/electron",
    "url": "https://github.com/electron/electron@${ELECTRON_COMMIT}",
    "deps_file": "DEPS",
    "managed": False,
    "custom_vars": {
      "checkout_mac": True,
      "host_os": "mac",
    },
  },
]
EOF
echo "[OK] Commit: ${ELECTRON_COMMIT:0:12}"
echo ""

# ══════════════════════════════════════════════════
#  ÉTAPE 3 : synchroniser les sources + hooks
# ══════════════════════════════════════════════════
HOOKS_DONE="$BUILD_DIR/src/build/util/LASTCHANGE.committime"

if [ -d "$BUILD_DIR/src/electron" ] && [ -d "$BUILD_DIR/src/build" ] && [ -f "$HOOKS_DONE" ]; then
    # Sources complètes + hooks déjà exécutés → rien à faire
    echo "[ÉTAPE 3/8] Sources et hooks déjà présents ✓"
    echo "            (supprime $BUILD_DIR/src pour forcer un re-sync)"
elif [ -d "$BUILD_DIR/src" ]; then
    # Sources corrompues ou hooks incomplets → supprimer et re-sync proprement
    echo "[ÉTAPE 3/8] État des sources incorrect — re-sync complet..."
    echo "            Suppression de src/ (les sources seront re-téléchargées)..."
    cd "$BUILD_DIR"
    rm -rf src
    echo "            Téléchargement des sources (~30-60 min)..."
    gclient sync --with_branch_heads --with_tags --no-history --nohooks -v
    echo ""
    echo "            Exécution des hooks..."
    gclient runhooks -v
else
    # Pas de sources → sync complet
    echo "[ÉTAPE 3/8] Téléchargement des sources Chromium + Electron..."
    echo "            ~30-60 min selon la connexion. Ne ferme pas le Terminal !"
    echo ""
    cd "$BUILD_DIR"
    gclient sync --with_branch_heads --with_tags --no-history --nohooks -v
    echo ""
    echo "          Exécution des hooks..."
    gclient runhooks -v
fi
echo "[OK] Sources synchronisées"
echo ""

# ══════════════════════════════════════════════════
#  ÉTAPE 4 : fichiers source PPAPI Flash (42 fichiers)
# ══════════════════════════════════════════════════
echo "[ÉTAPE 4/8] Fichiers source PPAPI Flash..."
cd "$BUILD_DIR/src"
SOURCES_TAR="$SCRIPT_DIR/ppapi-flash-sources.tar.gz"
if [ ! -f "$SOURCES_TAR" ]; then
    echo "            Téléchargement depuis GitHub..."
    curl -fSL "$PATCH_REPO/ppapi-flash-sources.tar.gz" -o /tmp/ppapi-flash-sources.tar.gz
    SOURCES_TAR="/tmp/ppapi-flash-sources.tar.gz"
fi
tar -xzf "$SOURCES_TAR"
FLASH_COUNT=$(ls ppapi/thunk/ppb_flash_* ppapi/proxy/flash_* ppapi/shared_impl/flash_* 2>/dev/null | wc -l | tr -d ' ')
echo "[OK] $FLASH_COUNT fichiers extraits"
echo ""

# ══════════════════════════════════════════════════
#  ÉTAPE 5 : appliquer le patch PPAPI
# ══════════════════════════════════════════════════
echo "[ÉTAPE 5/8] Patch PPAPI Flash..."
cd "$BUILD_DIR/src"
if grep -q "application/x-shockwave-flash" content/common/pepper_plugin_list.cc 2>/dev/null; then
    echo "[OK] Patch déjà appliqué ✓"
else
    PATCH_FILE="$SCRIPT_DIR/ppapi-flash-full.patch"
    if [ ! -f "$PATCH_FILE" ]; then
        echo "            Téléchargement depuis GitHub..."
        curl -fSL "$PATCH_REPO/ppapi-flash-full.patch" -o /tmp/ppapi-flash-full.patch
        PATCH_FILE="/tmp/ppapi-flash-full.patch"
    fi
    git apply "$PATCH_FILE"
    echo "[OK] 28 fichiers patchés"
fi
echo ""

# ══════════════════════════════════════════════════
#  ÉTAPE 6 : GN gen
# ══════════════════════════════════════════════════
echo "[ÉTAPE 6/8] Configuration du build (GN gen $TARGET_CPU)..."
cd "$BUILD_DIR/src/electron"
git pack-refs --all 2>/dev/null || true
cd "$BUILD_DIR/src"

GN_ARGS="import(\"//electron/build/args/release.gn\") enable_ppapi = true enable_plugins = true target_cpu = \"$TARGET_CPU\""

if [ "$TARGET_CPU" = "x64" ] && [ "$(uname -m)" = "arm64" ]; then
    GN_ARGS="$GN_ARGS v8_snapshot_toolchain = \"//build/toolchain/mac:clang_x64\""
fi

# Xcode 26+ / macOS 26 SDK : les headers introduisent des symboles NSAccessibility*
# qui entrent en conflit avec les définitions privées de Chromium.
# On désactive les warnings -Werror pour ces cas spécifiques.
SDK_VER=$(xcrun --show-sdk-version 2>/dev/null | cut -d. -f1)
if [ -n "$SDK_VER" ] && [ "$SDK_VER" -ge 26 ] 2>/dev/null; then
    echo "[INFO] SDK macOS $SDK_VER détecté — ajout de flags de compatibilité"
    GN_ARGS="$GN_ARGS treat_warnings_as_errors = false"
fi

buildtools/mac/gn gen "out/Release-${TARGET_CPU}" --args="$GN_ARGS"
echo "[OK] Build configuré"
echo ""

# ══════════════════════════════════════════════════
#  ÉTAPE 7 : compilation
# ══════════════════════════════════════════════════
echo "[ÉTAPE 7/8] Compilation d'Electron ($TARGET_CPU)..."
echo "            Ça va prendre 2-4 heures."
echo "            NE FERME PAS le Terminal !"
echo ""

NCPU=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)
JOBS=$(( NCPU - 2 ))
if [ "$JOBS" -lt 2 ]; then JOBS=2; fi
echo "[INFO] $NCPU coeurs détectés, compilation avec $JOBS threads"
echo ""

cd "$BUILD_DIR/src"
autoninja -C "out/Release-${TARGET_CPU}" electron -j "$JOBS"

echo ""
echo "[OK] Compilation terminée !"
echo ""

# ══════════════════════════════════════════════════
#  ÉTAPE 8 : packaging
# ══════════════════════════════════════════════════
echo "[ÉTAPE 8/8] Packaging..."
OUTPUT_FILE="$HOME/Desktop/Electron-mac-${TARGET_CPU}.tar.gz"
cd "$BUILD_DIR/src/out/Release-${TARGET_CPU}"

if [ ! -d "Electron.app" ]; then
    echo "[ERREUR] Electron.app introuvable dans out/Release-${TARGET_CPU}/"
    echo "         La compilation a peut-être échoué."
    exit 1
fi

tar -czf "$OUTPUT_FILE" Electron.app/
SIZE=$(du -h "$OUTPUT_FILE" | cut -f1)

echo ""
echo "========================================"
echo "  BUILD TERMINÉ !"
echo "========================================"
echo ""
echo "  Fichier : $OUTPUT_FILE"
echo "  Taille  : $SIZE"
echo "  Arch    : macOS $TARGET_CPU"
echo ""
echo "  Le fichier est sur le Bureau."
echo "  Envoie-le par WeTransfer, Google Drive,"
echo "  ou clé USB."
echo ""
echo "========================================"
