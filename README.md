# LuaTools aarch64 stack — offline bundle

Instala SLSsteam (build aarch64 corrigido), Lumen e o plugin LuaTools a partir de
binários já validados. Não compila nada e não baixa o plugin/SLSsteam.

## Conteúdo

| Item | Origem |
| --- | --- |
| `installer.sh` | instalador completo (wrapper Steam Runtime, depots, plugin, Game Mode opcional, fix do overlay FEX) |
| `artifacts/slsteam/SLSsteam.so` | build aarch64 com injeção de depots para apps sem licença e guarda de shader (`depotId == appId`) |
| `artifacts/lumen.zip` | binário do Lumen + árvore `lua/` |
| `artifacts/luatools-linux.zip` | plugin LuaTools v2.9 (sem `backend/data`, com `7zz` aarch64) |
| `artifacts/7zz` | 7-Zip aarch64 para fixes `.rar` |

`SHA256SUMS` cobre todos os arquivos acima.

## Requisitos

- Armada OS / SteamOS-like **aarch64**, Steam nativa já aberta uma vez (primeiro setup concluído).
- `curl`, `tar`, `unzip`, `jq`, `sha256sum` (o instalador instala se faltar).
- `sudo` para o drop-in do FEX e, se necessário, pacotes.

## Uso local

```bash
cd luatools-stack-armada
sudo ./install.sh              # ou: bash install.sh
```

Flags repassadas ao instalador: `--nolaunch`, `--noplugin`, `--no-gamemode`, `--uninstall`, `--purge`.

## Uso via curl (repositório privado)

Repositório privado exige token no header (raw.githubusercontent.com não serve
conteúdo privado sem autenticação):

```bash
export GH_TOKEN=...   # fine-grained com Contents: Read (ou classic com repo)

curl -fsSL -H "Authorization: Bearer $GH_TOKEN" \
  https://raw.githubusercontent.com/USER/luatools-stack-armada/main/install.sh \
  | BUNDLE_BASE_URL=https://raw.githubusercontent.com/USER/luatools-stack-armada/main \
    BUNDLE_AUTH_HEADER="Authorization: Bearer $GH_TOKEN" bash
```

O bootstrap repassa o header em cada download dos artefatos.

## Uso via curl (pasta hospedada)

Sirva a pasta em qualquer host estático e rode:

```bash
curl -fsSL https://SEU-HOST/luatools-stack-armada/install.sh \
  | BUNDLE_BASE_URL=https://SEU-HOST/luatools-stack-armada bash
```

O bootstrap baixa os artefatos para `~/.local/share/Lumen/bundle` e chama o
instalador com eles. Para testar em LAN:

```bash
python3 -m http.server 8000     # dentro da pasta pai
curl -fsSL http://IP:8000/luatools-stack-armada/install.sh \
  | BUNDLE_BASE_URL=http://IP:8000/luatools-stack-armada bash
```

## O que o instalador faz

1. Verifica arch, ferramentas de runtime e a Steam nativa inicializada.
2. Instala o SLSsteam em `~/.local/share/SLSsteam` e o wrapper do Steam Runtime
   (`steamrtarm64/steam` → `steam.real`) com o watcher `slssteam-wrap.path`.
3. Instala o Lumen (`~/.local/share/Lumen`) e o plugin em `lumen/luatools`.
4. Aplica os patches aarch64 do plugin (7zz, `steam.real`, downloader).
5. Instala o drop-in `armada-guestos.service.d/verify-overlay.conf` (remonta o
   overlay do FEX se ele subir vazio).
6. Escreve `~/.local/share/Lumen/install.conf`, usado pelo *Update All* do Lumen.

## Observações

- Não inclui jogos nem `~/.config/SLSsteam` (config do usuário).
- `backend/data` foi removido do plugin (continha idioma e a API key do Hubcap);
  o plugin recria com os defaults no primeiro uso.
- O *Update All* do Lumen reaproveita os caminhos salvos em `install.conf`; mantenha
  a pasta do bundle (ou o cache em `~/.local/share/Lumen/bundle`) no lugar.
- Desinstalar: `sudo ./install.sh --uninstall` (mantém `~/.config/SLSsteam`).
