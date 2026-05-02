#!/usr/bin/env bash
# Generates SVG diagrams from Mermaid (.mmd) files into DocC Resources.
# Requires: npm install -g @mermaid-js/mermaid-cli
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIAGRAMS_DIR="$REPO_DIR/JeballtoAgent/JeballtoAgent.docc/Diagrams"
RESOURCES_DIR="$REPO_DIR/JeballtoAgent/JeballtoAgent.docc/Resources"

command -v mmdc &>/dev/null || { echo "Error: mmdc not found. Install: npm install -g @mermaid-js/mermaid-cli"; exit 1; }
mkdir -p "$RESOURCES_DIR"

for mmd in "$DIAGRAMS_DIR"/*.mmd; do
  name="$(basename "$mmd" .mmd)"
  echo "Generating $name.svg..."
  mmdc -i "$mmd" -o "$RESOURCES_DIR/$name.svg" --configFile "$DIAGRAMS_DIR/config.json" --backgroundColor "#0d0f14"
done

echo "Done."
