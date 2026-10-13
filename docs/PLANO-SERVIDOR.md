# Plano: ferramenta de animação de personagem no servidor Ubuntu

Alvo: `192.168.15.11` (SSH na porta 2222), RTX 5060 Ti 16 GB (Blackwell, sm_120), Xeon, ~40 GB RAM.
Projeto **independente**: usuário, pasta (`/opt/comfy`), venv e porta próprios. Não usa Docker e não toca em nenhum serviço que já exista no servidor.

## 0. Decisões que moldam o plano

| Tema | Decisão | Motivo |
|---|---|---|
| WarpTuber "como está" no servidor | **Não** | É um pacote Windows (`.bat`, venv embutido, `.trt` compilados) em cima do FasterLivePortrait com **TensorRT 8.x**. TensorRT 8 não suporta Blackwell; o próprio FasterLivePortrait avisa que TRT ≥10 não é compatível. Portar isso é trabalho de pesquisa, não instalação. |
| Motor de animação no servidor | **LivePortrait em PyTorch via ComfyUI** (`ComfyUI-LivePortraitKJ` + `ComfyUI-AdvancedLivePortrait`) | Mesmos pesos do LivePortrait, roda em PyTorch cu128+, que é o que funciona hoje em Blackwell. |
| Instalação do ComfyUI | **venv nativo + systemd** (não Docker) | O Manager instala nodes e pacotes pip em tempo de execução; em container isso some a cada recriação ou exige volume do venv inteiro. Nativo isola por usuário/venv e usa o driver do host sem alterar nada do que já está instalado. |
| Python | **3.12** | Compatível com torch cu128+, mediapipe e a maioria dos custom nodes. 3.13 ainda quebra nodes de visão. |
| Manager | **Fork `teste0102/ComfyUI-Manager`** clonado em `custom_nodes/comfyui-manager` | É o fork do projeto; dá para customizar canais/políticas depois. |
| Exposição na rede | `--listen 192.168.15.11 --port 8188` + `ufw` só para a LAN | ComfyUI não tem autenticação. Ver seção 4. |
| Webcam em tempo real | **Fase 5, com critério de go/no-go** | A webcam e o OBS estão no PC Windows, não no servidor. Tempo real no servidor exige streaming ida e volta pela LAN. |

## Por que o WarpTuber original não roda na 5060 Ti

- O WarpTuber é o FasterLivePortrait empacotado para **Windows** (`.bat`, venv do Windows embutido) e roda os modelos como motores **TensorRT 8.x** (`.trt`).
- A 5060 Ti é **Blackwell** (compute capability 12.0). Blackwell só é suportada a partir do **CUDA 12.8** e do **TensorRT 10.8**. O TensorRT 8 não conhece essa arquitetura, então não consegue gerar nem carregar os `.trt` nela.
- O FasterLivePortrait declara que TensorRT 10 não é compatível com o código dele, e o plugin `grid-sample3d` que ele precisa é compilado só até a arquitetura 86 (RTX 30xx).
- O **LivePortrait em si roda** na 5060 Ti: em PyTorch com CUDA 12.8+ funciona. Por isso o plano usa os mesmos modelos do LivePortrait via ComfyUI.

## 1. Pré-checagem (não instala nada)

Script: [`deploy/comfyui/preflight.sh`](../deploy/comfyui/preflight.sh). Rodar no servidor:

```bash
ssh -p 2222 <usuario>@192.168.15.11
bash preflight.sh
```

Ele confere e imprime:
- Driver NVIDIA ≥ 570 (mínimo para CUDA 12.8 / Blackwell). Com driver ≥ 580 dá para usar wheels cu130.
- VRAM livre na GPU.
- Porta 8188 livre (se estiver ocupada, troca-se a porta do ComfyUI; nada existente é alterado).
- Disco livre na partição de destino (meta: ≥ 80 GB para modelos).
- `python3.12`, `git`, `ffmpeg`, `ufw` presentes.

**Saída esperada**: tudo `OK`, ou a lista do que falta. Não seguir para a fase 2 com driver < 570.

## 2. Instalação ComfyUI + Manager

Script: [`deploy/comfyui/install.sh`](../deploy/comfyui/install.sh) (idempotente, roda como usuário `comfy`, sem sudo exceto para criar o usuário/serviço).

O que ele faz:
1. Cria o usuário de sistema `comfy` com home `/opt/comfy` (sem login).
2. `git clone` do ComfyUI em `/opt/comfy/ComfyUI`.
3. venv Python 3.12 com `uv`; instala `torch torchvision torchaudio` do índice `cu128` (troca para `cu130` com `TORCH_CUDA=cu130` se o driver for ≥ 580).
4. `requirements.txt` do ComfyUI.
5. Clona o fork `teste0102/ComfyUI-Manager` em `custom_nodes/comfyui-manager` e instala os requisitos dele.
6. Copia o `config.ini` seguro para `ComfyUI/user/__manager/config.ini` (caminho usado pelo Manager em ComfyUI recente).
7. Valida: `python -c "import torch; print(torch.cuda.get_device_capability())"` precisa retornar `(12, 0)`.

Alternativa equivalente: `pip install comfy-cli && comfy install` (método 3 do README do Manager). Não uso aqui porque instala o Manager upstream, não o fork, e escolhe o índice do torch sozinho.

## 3. Serviço systemd

Unit: [`deploy/comfyui/comfyui.service`](../deploy/comfyui/comfyui.service).

Pontos importantes:
- `--listen 192.168.15.11 --port 8188` (nunca `0.0.0.0` se o host tiver outra interface fora da LAN).
- `MemoryMax=24G`: o ComfyUI nunca consome a RAM do servidor inteiro.
- `Restart=on-failure`, logs no `journalctl -u comfyui`.

```bash
sudo cp comfyui.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now comfyui
journalctl -u comfyui -f
```

## 4. Segurança (config.ini + firewall)

Arquivo: [`deploy/comfyui/config.ini`](../deploy/comfyui/config.ini).

```ini
[default]
security_level = normal
network_mode = public
allow_git_url_install = false
allow_pip_install = false
allow_flagged_nodepack_install = false
file_logging = True
use_uv = True
```

Como isso se comporta com `--listen 192.168.15.11` (não-loopback), conferido no código do fork:
- **Permitido pela UI**: instalar/atualizar/remover nodes do canal padrão, restaurar snapshot, reiniciar.
- **Bloqueado pela UI**: "Install via Git URL", "pip install" e versões marcadas como flagged. Os flags `allow_*` só valem em listener loopback, então em LAN ficam negados mesmo se alguém mudar para `true`.
- `weak` e `normal-` são rebaixados automaticamente para `normal` pelo próprio Manager em listener remoto; não adianta tentar.
- Para instalar algo fora do canal (repo git específico), usar o `cm-cli` via SSH, que é operação local de administrador:
  ```bash
  sudo -u comfy /opt/comfy/venv/bin/python /opt/comfy/ComfyUI/custom_nodes/comfyui-manager/cm-cli.py install <nome-ou-url>
  ```

Firewall (ComfyUI não tem login, então a porta só pode ser vista pela LAN). **Só se o ufw já estiver ativo** (`sudo ufw status` mostra `Status: active`):
```bash
sudo ufw allow from 192.168.15.0/24 to any port 8188 proto tcp
sudo ufw deny 8188/tcp
```
Se estiver inativo, **não ativar**: ligar o ufw sem regras para o resto bloquearia o SSH (2222) e os outros serviços do servidor. Nesse caso o `--listen` no IP da LAN já basta.
Se no futuro precisar de acesso de fora: Tailscale ou reverse proxy com autenticação. Nunca encaminhar a 8188 no roteador.

## 5. Custom nodes e modelos

Instalar pela UI do Manager (todos estão no canal padrão), nesta ordem:

| Node | Para quê |
|---|---|
| `ComfyUI-VideoHelperSuite` | Carregar/salvar vídeo (driving video e saída). |
| `ComfyUI-LivePortraitKJ` (kijai) | Retrato + vídeo de referência → vídeo animado. Usa detector **MediaPipe** (sem a licença não comercial do InsightFace). |
| `ComfyUI-AdvancedLivePortrait` (PowerHouseMan) | Editor de expressões (olhos, boca, cabeça) e sequências de expressões por keyframe. É o "criar personagem com expressões". |
| `ComfyUI-KJNodes` | Utilitários (resize, batch, etc.) usados nos workflows de exemplo. |

Modelos LivePortrait: os dois nodes baixam sozinhos na primeira execução para `models/liveportrait` (repositório `Kijai/LivePortrait_safetensors` no Hugging Face), ~500 MB. Nada de `.trt` nem ONNX.

Para **gerar o personagem** (imagem do rosto) antes de animar, um modelo base. Recomendação para 16 GB:
- **SDXL** (ex.: Juggernaut XL) em `models/checkpoints/` — cabe folgado nos 16 GB.
- Opcional depois: um modelo de edição de imagem (Flux Kontext / Qwen-Image-Edit em fp8) para manter o mesmo personagem em variações. Só quando a fase 3 estiver estável.

## 6. Fases até a ferramenta final

| Fase | Entrega | Pronto quando |
|---|---|---|
| **1. Base** | Pré-checagem + ComfyUI + Manager + systemd + firewall | `http://192.168.15.11:8188` abre de um PC da LAN, `torch` vê `(12, 0)`. |
| **2. Animação offline** | Nodes da seção 5 + workflow "retrato + vídeo da webcam gravado → vídeo animado" salvo em `workflows/` neste repo | Gera um clipe de 10 s em 512×512 sem erro de VRAM. |
| **3. Personagem** | Workflow SDXL → rosto do personagem → AdvancedLivePortrait (expressões) | Personagem gerado e animado a partir de um único prompt. |
| **4. Interface simples** | Página web leve (ou API do ComfyUI chamada por script) com: subir foto/gerar personagem, subir vídeo, baixar resultado | Uso sem abrir o grafo do ComfyUI. |
| **5. Tempo real (go/no-go)** | Ver abaixo | ≥ 25 fps e < 150 ms de atraso fim a fim na LAN. |

### Fase 5: tempo real

A webcam e o OBS estão no PC Windows. Duas rotas, decidir com números:

- **A. Tempo real no PC Windows (WarpTuber atual)**. Já está montado; falta só copiar o cuDNN 8.9.7 para dentro do CUDA Toolkit e rodar `scripts\all_onnx2trt.bat`. O servidor fica com geração de personagem e render offline. **É a rota recomendada se a GPU do PC for NVIDIA RTX 20xx–40xx.**
- **B. Tempo real no servidor**. Navegador do PC envia a webcam por WebRTC → serviço no servidor roda LivePortrait (PyTorch, `torch.compile`) → devolve o vídeo → OBS captura a janela/virtual cam. Protótipo de 1 dia para medir fps e latência; só vira produto se passar no critério. Porta separada (ex.: 9870), também só LAN.

## 7. Riscos

- **Nodes que compilam CUDA** (ex.: insightface, alguns de face swap) podem não ter build para sm_120. Ficar nos nodes da seção 5 até a fase 3.
- **Atualizações do ComfyUI** quebram nodes: usar snapshot do Manager antes de cada update.

## 8. Rollback

```bash
sudo systemctl disable --now comfyui
sudo rm /etc/systemd/system/comfyui.service
sudo ufw delete allow from 192.168.15.0/24 to any port 8188 proto tcp
sudo ufw delete deny 8188/tcp
sudo userdel comfy && sudo rm -rf /opt/comfy
```
Remove só o que este projeto criou.
