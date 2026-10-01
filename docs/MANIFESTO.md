# Manifesto — Contrato `manifest.json`

Esquema: [manifest.schema.json](../manifest.schema.json)

## Principios

1. Nenhum valor volatil no script: caminhos, versoes, hashes e pastas moram no manifesto.
2. Campo com valor `TODO` faz o manifesto ser rejeitado em execucao normal (`exit 12`) e apenas listado em `-DryRun`.
3. `detect` decide se o componente ja esta instalado; `validate` confirma que a instalacao deu certo. Sao listas independentes e todos os predicados precisam ser verdadeiros.

## Raiz

| Campo | Tipo | Obrigatorio | Descricao |
|-------|------|:-----------:|-----------|
| `schemaVersion` | int | Sim | Versao do esquema (atual: 1) |
| `packageVersion` | string | Sim | Versao logica do kit |
| `packageRoot` | string | Nao | Pasta dos pacotes, relativa ao kit (padrao: raiz do kit) |
| `minFreeDiskBytes` | int | Nao | Espaco minimo exigido em C: |
| `components` | array | Sim | Lista de componentes |

## Componente

| Campo | Tipo | Descricao |
|-------|------|-----------|
| `id` | string | `driver_cdm20824`, `ioterminal`, `d2xx_runtime` ou `license_idmonact` |
| `displayName` | string | Nome legivel, usado no log e no atalho |
| `kind` | string | `driver-archive`, `portable-archive`, `dll-copy` ou `license-copy` |
| `order` | int | Ordem de execucao |
| `detect` / `validate` | predicate[] | Predicados de deteccao e de validacao |
| `uninstall` | object | Metodo de reversao |
| `timeoutSeconds` | int | Timeout do componente |

### `kind: driver-archive`

| Campo | Descricao |
|-------|-----------|
| `archive` | `.rar` com o empacotador do driver |
| `sha256` | Hash do `.rar` |
| `innerExeMatch` | Padroes para achar o executavel dentro do `.rar` |
| `innerSha256` | Hash do executavel interno |
| `driverInf` | Nomes dos `.inf` a publicar, em ordem |
| `skipKernelBuild` | Se o Windows tiver esse build ou maior (22000 = Windows 11), nao publica o kernel 2.08.24; publica o pacote `modernArchive` (CDM 2.12 WHQL) |
| `modernArchive` | ZIP do kernel WHQL 2.12 usado no Windows 11 |
| `modernSha256` | Hash do ZIP moderno |
| `modernDriverVersion` | Versao do kernel moderno (ex.: `2.12.36.20`) |

O fluxo extrai o `.rar`, extrai o executavel interno e publica cada `.inf` com `pnputil /add-driver <inf> /install /subdirs`. O executavel do fabricante nunca e executado. Isso **nao** copia a `ftd2xx.dll`; essa copia e o `kind: dll-copy`.

### `kind: portable-archive`

| Campo | Descricao |
|-------|-----------|
| `archive` | `.rar` da aplicacao |
| `sha256` | Hash do `.rar` |
| `installDir` | Pasta de destino |
| `mainExe` | Executavel principal, relativo a `installDir` |
| `runAsAdministrator` | Marca o executavel para abrir sempre elevado |
| `desktopShortcut` | Cria atalho na area de trabalho publica |

Se o `.rar` tiver uma unica pasta na raiz, ela e achatada para nao gerar pasta dentro de pasta.

### `kind: dll-copy`

| Campo | Descricao |
|-------|-----------|
| `fromComponent` | Id do `driver-archive` de onde vem o pacote ja extraido |
| `files` | Pares `source` (relativo ao pacote extraido) / `target` (destino no sistema) |

O IOT Multitool e 32 bits e protegido pelo Themida, que procura `FTD2XX.DLL` via `GetSystemDirectory()`. Em Windows 64 bits isso e `SysWOW64`, nao a pasta do programa. Destinos tipicos:

```json
{ "source": "i386\\ftd2xx.dll", "target": "{installDir}\\ftd2xx.dll" }
{ "source": "i386\\ftd2xx.dll", "target": "{syswow64}\\ftd2xx.dll" }
```

Tokens de caminho: `{installDir}`, `{syswow64}` (em Windows 32 bits cai no `System32`) e `{system32}`.

### `kind: license-copy`

| Campo | Descricao |
|-------|-----------|
| `source` | Pasta da licenca dentro dos pacotes |
| `targetSubDir` | Subpasta criada dentro de `installDir` |

Uma licenca ja existente no destino e movida para `<nome>.bak-<timestamp>` antes da copia.

## Predicados

```json
{ "type": "file", "path": "{installDir}\\iot_MULTITOOLv50B.exe", "minVersion": "1.0.0.0" }
{ "type": "dir", "path": "{installDir}\\IDMONACT", "containsPattern": "*.bin", "recurse": true }
{ "type": "driver", "originalName": "ftdibus.inf", "driverVersion": "2.8.24.0" }
{ "type": "registry", "path": "HKLM:\\SOFTWARE\\...", "name": "Valor", "expectedValue": "1" }
{ "type": "service", "name": "NomeServico", "state": "Running" }
```

O token `{installDir}` e substituido pela pasta do componente `ioterminal` (do manifesto ou do `state.json`). `{syswow64}` aponta para `SysWOW64` em Windows 64 bits e para `System32` em Windows 32 bits. `{system32}` aponta para o `System32` real.

`driverVersion` e obrigatorio na pratica para drivers FTDI: o Windows traz versoes 2.12.x de fabrica e, sem o filtro, o driver do kit seria considerado presente.

## `uninstall`

| kind | Campos | Efeito |
|------|--------|--------|
| `driver` | `originalNames[]`, `driverVersion` | `pnputil /delete-driver <oemN.inf> /uninstall /force` apenas nas versoes indicadas |
| `remove-dir` | `path` | Remove a pasta (aceita `{installDir}`) |
| `remove-file` | `paths[]` | Remove cada arquivo (aceita `{installDir}` e `{syswow64}`) |

## `pnpDevices`

```json
{ "hardwareId": "USB\\VID_0403", "optional": true }
```

Com `optional: true`, dispositivo ausente gera `WARN` e nao falha: significa apenas que a interface USB nao esta conectada. Code 52 gera `exit 43` e Code 43 gera `exit 44`.

## Historico

| Versao | Data | Alteracao |
|--------|------|-----------|
| 2026.09.16 | 2026-09-16 | Manifesto inicial preenchido com hashes e predicados reais do kit |
