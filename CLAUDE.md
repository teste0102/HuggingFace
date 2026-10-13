# Projeto

Contexto de trabalho envolvendo animação facial em tempo real (WarpTuber/LivePortrait) e gerenciamento de nodes do ComfyUI.

## Repositórios relacionados

- **Hugging Face — WarpTuber**: https://huggingface.co/sikavial/WarpTuber
  Fork público de `AIWarper/WarpTuber`. Ferramenta de animação facial em tempo real via webcam (LivePortrait), roda local no Windows com GPU NVIDIA (CUDA/TensorRT).
- **GitHub — ComfyUI-Manager**: https://github.com/teste0102/ComfyUI-Manager
  Fork de `ltdrdata/ComfyUI-Manager`. Extensão para gerenciar custom nodes do ComfyUI (instalar/remover/habilitar, hub de nodes).

## Ambiente local (máquina Windows do usuário)

- Projeto local em `C:\Users\User\Desktop\face`
- Dependência: cuDNN 8.9.7 para CUDA 12, em `C:\Users\User\Desktop\face\cudnn-windows-x86_64-8.9.7.29_cuda12-archive` — estrutura completa e verificada (bin/include/lib/x64 + LICENSE). Precisa ser copiada para dentro do CUDA Toolkit instalado para ter efeito.
- Acesso a essa pasta só é possível via sessão local do Claude Code (Desktop app ou `claude remote-control`), não pela sessão em nuvem.

## Servidor Linux (alvo do projeto)

- Ubuntu `192.168.15.11` (SSH porta 2222), RTX 5060 Ti 16 GB (Blackwell): exige driver >= 570 e PyTorch cu128+. TensorRT 8 (base do WarpTuber/FasterLivePortrait) não roda em Blackwell.
- Projeto independente de qualquer outro serviço do servidor: usuário `comfy`, pasta `/opt/comfy`, porta 8188, sem Docker. Nunca mencionar nem mexer em outros serviços do host.
- Plano: `docs/PLANO-SERVIDOR.md`. Arquivos de deploy: `deploy/comfyui/`.
