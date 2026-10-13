#!/usr/bin/env bash
# Instala ComfyUI + fork do ComfyUI-Manager em /opt/comfy, como usuário de sistema "comfy".
# Idempotente: pode rodar de novo para atualizar dependências.
# Uso: sudo bash install.sh            (cu128, padrão)
#      sudo TORCH_CUDA=cu130 bash install.sh   (driver >= 580)
set -euo pipefail

COMFY_USER=comfy
COMFY_HOME=/opt/comfy
COMFY_DIR="$COMFY_HOME/ComfyUI"
VENV="$COMFY_HOME/venv"
TORCH_CUDA="${TORCH_CUDA:-cu128}"
MANAGER_REPO="${MANAGER_REPO:-https://github.com/teste0102/ComfyUI-Manager}"
HERE="$(cd "$(dirname "$0")" && pwd)"

[ "$(id -u)" -eq 0 ] || { echo "Rode com sudo."; exit 1; }

if ! id "$COMFY_USER" >/dev/null 2>&1; then
  useradd --system --home-dir "$COMFY_HOME" --create-home --shell /usr/sbin/nologin "$COMFY_USER"
  usermod -aG video,render "$COMFY_USER" 2>/dev/null || true
fi

as_comfy() { sudo -u "$COMFY_USER" -H env PATH="$COMFY_HOME/.local/bin:$PATH" bash -c "$1"; }

# uv (gerenciador de venv/pip)
as_comfy 'command -v uv >/dev/null || curl -LsSf https://astral.sh/uv/install.sh | sh'

# ComfyUI
as_comfy "[ -d '$COMFY_DIR/.git' ] || git clone https://github.com/comfyanonymous/ComfyUI '$COMFY_DIR'"
as_comfy "git -C '$COMFY_DIR' pull --ff-only"

# venv Python 3.12 + torch para Blackwell
as_comfy "[ -x '$VENV/bin/python' ] || uv venv --python 3.12 '$VENV'"
as_comfy "VIRTUAL_ENV='$VENV' uv pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/$TORCH_CUDA"
as_comfy "VIRTUAL_ENV='$VENV' uv pip install -r '$COMFY_DIR/requirements.txt'"

# Manager (fork do projeto)
MGR="$COMFY_DIR/custom_nodes/comfyui-manager"
as_comfy "[ -d '$MGR/.git' ] || git clone '$MANAGER_REPO' '$MGR'"
as_comfy "git -C '$MGR' pull --ff-only"
as_comfy "VIRTUAL_ENV='$VENV' uv pip install -r '$MGR/requirements.txt'"

# config.ini seguro (não sobrescreve um existente)
CFG_DIR="$COMFY_DIR/user/__manager"
install -d -o "$COMFY_USER" -g "$COMFY_USER" "$CFG_DIR"
if [ ! -f "$CFG_DIR/config.ini" ]; then
  install -o "$COMFY_USER" -g "$COMFY_USER" -m 0640 "$HERE/config.ini" "$CFG_DIR/config.ini"
else
  echo "config.ini já existe em $CFG_DIR; mantido. Compare com $HERE/config.ini."
fi

# Validação: Blackwell = compute capability (12, 0)
as_comfy "'$VENV/bin/python' -c 'import torch; assert torch.cuda.is_available(), \"CUDA indisponível\"; print(torch.__version__, torch.version.cuda, torch.cuda.get_device_name(0), torch.cuda.get_device_capability(0))'"

echo "Instalado. Próximo passo: sudo cp $HERE/comfyui.service /etc/systemd/system/ && sudo systemctl daemon-reload && sudo systemctl enable --now comfyui"
