#!/usr/bin/env bash
# Pré-checagem do servidor para o ComfyUI. Só lê; não instala nem altera nada.
set -u

COMFY_PORT="${COMFY_PORT:-8188}"
TARGET_DIR="${TARGET_DIR:-/opt}"
MIN_DRIVER=570
MIN_DISK_GB=80

ok()   { printf '  [OK]   %s\n' "$*"; }
warn() { printf '  [WARN] %s\n' "$*"; }
fail() { printf '  [FAIL] %s\n' "$*"; FAILED=1; }
FAILED=0

echo "== GPU / driver"
if command -v nvidia-smi >/dev/null; then
  nvidia-smi --query-gpu=name,driver_version,memory.used,memory.total,compute_cap --format=csv,noheader
  drv=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1 | cut -d. -f1)
  if [ "$drv" -ge "$MIN_DRIVER" ]; then ok "driver $drv >= $MIN_DRIVER (CUDA 12.8)"; else fail "driver $drv < $MIN_DRIVER: Blackwell exige >= $MIN_DRIVER"; fi
  [ "$drv" -ge 580 ] && ok "driver >= 580: pode usar TORCH_CUDA=cu130"
  echo "  Processos usando a GPU agora (Frigate deve aparecer aqui):"
  nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader | sed 's/^/    /'
else
  fail "nvidia-smi não encontrado"
fi

echo "== Portas"
if ss -ltn "( sport = :$COMFY_PORT )" | grep -q LISTEN; then
  fail "porta $COMFY_PORT já está em uso"
else
  ok "porta $COMFY_PORT livre"
fi
echo "  Tudo que escuta hoje (conferir Frigate 5000/8971/8554/8555/1984 e a loja):"
ss -ltnp 2>/dev/null | awk 'NR>1 {print "    " $4 "  " $6}' | sort -u

echo "== Docker"
if command -v docker >/dev/null; then
  docker ps --format '    {{.Names}}  {{.Ports}}' 2>/dev/null || warn "sem permissão para docker ps (rode com sudo para ver)"
fi

echo "== Disco em $TARGET_DIR"
free_gb=$(df -BG --output=avail "$TARGET_DIR" | tail -1 | tr -dc '0-9')
if [ "$free_gb" -ge "$MIN_DISK_GB" ]; then ok "${free_gb} GB livres"; else warn "só ${free_gb} GB livres (meta ${MIN_DISK_GB} GB)"; fi

echo "== Memória"
free -g | sed 's/^/    /'

echo "== Ferramentas"
for t in git ffmpeg ufw curl; do
  if command -v "$t" >/dev/null; then ok "$t"; else fail "$t ausente (sudo apt install $t)"; fi
done
if command -v python3.12 >/dev/null; then ok "python3.12"; else warn "python3.12 ausente: o install.sh usa o Python gerenciado pelo uv"; fi

echo
if [ "$FAILED" -eq 0 ]; then echo "Pré-checagem OK."; else echo "Corrigir os [FAIL] antes do install.sh."; exit 1; fi
