#!/usr/bin/env bash
# mlxtranslate : installation locale (idempotente).
#
#   - construit l'exécutable en release,
#   - le copie dans ~/.local/bin (ajouté au PATH si besoin),
#   - prépare le dossier ~/.mlxtranslate (glossaire vierge, sidecar).
#
# Relançable à volonté : ne casse rien s'il existe déjà.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_NAME="mlxtranslate"
HOME_DIR="${MLXTRANSLATE_HOME:-$HOME/.mlxtranslate}"
DEST_DIR="${MLXTRANSLATE_DEST:-$HOME/.local/bin}"

echo "==> mlxtranslate — installation (repo : $REPO)"

# 1. Build release (idempotent : swift recompile seulement si changé).
echo "==> swift build -c release"
cd "$REPO"
swift build -c release

RELEASE_BIN=".build/release/$BIN_NAME"
if [[ ! -x "$RELEASE_BIN" ]]; then
  echo "ERREUR : binaire release introuvable ($RELEASE_BIN)" >&2
  exit 1
fi

# 2. Copie dans DEST_DIR (idempotent : surcharge).
mkdir -p "$DEST_DIR"
cp -f "$RELEASE_BIN" "$DEST_DIR/$BIN_NAME"
chmod +x "$DEST_DIR/$BIN_NAME"
echo "==> installé : $DEST_DIR/$BIN_NAME"

# 3. Prépare ~/.mlxtranslate (idempotent : ne réécrit pas le glossaire existant).
mkdir -p "$HOME_DIR" "$HOME_DIR/sidecar" "$HOME_DIR/speakerkit"
if [[ ! -f "$HOME_DIR/glossaire.txt" ]]; then
  : > "$HOME_DIR/glossaire.txt"
  echo "==> glossaire vierge créé : $HOME_DIR/glossaire.txt"
fi

# 4. PATH : signale (sans modifier le .zshrc à notre place).
case ":$PATH:" in
  *":$DEST_DIR:"*) ;;
  *) echo "==> astuce : $DEST_DIR n'est pas dans le PATH. Ajoutez : export PATH=\"$DEST_DIR:\$PATH\"" ;;
esac

echo "==> OK. Test : $DEST_DIR/$BIN_NAME --help"
