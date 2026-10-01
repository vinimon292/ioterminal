# Codigos de saida — Instalador IOTerminal

Cada falha grava no log: codigo, componente, etapa, causa provavel e acao sugerida.

## Sucesso

| Codigo | Significado | Acao |
|:------:|-------------|------|
| 0 | Sucesso | Nenhuma |
| 3010 | Sucesso, reinicio pendente | Reiniciar e conferir o IOTerminal |

## Pre-execucao

| Codigo | Significado | Acao sugerida |
|:------:|-------------|---------------|
| 10 | Sem privilegio administrativo | Executar como admin e aceitar o UAC |
| 11 | Parametro invalido (DryRun + Rollback/Force) | Corrigir a linha de comando |
| 12 | Manifesto invalido, ilegivel ou com TODO | Rodar `-DryRun` para listar lacunas |
| 13 | PowerShell inferior a 5.1 | Usar PowerShell 5.1 Desktop |
| 14 | Espaco livre insuficiente em C: | Liberar espaco |

## Pacotes e extracao

| Codigo | Significado | Acao sugerida |
|:------:|-------------|---------------|
| 20 | Arquivo do pacote ou do extrator ausente | Conferir a pasta `IOTERMINAL`, a pasta `ferramentas` ou `-PackageDir` |
| 21 | SHA-256 divergente (pacote ou extrator embutido) | Repor o arquivo original do kit; divergencia no extrator nao deve ser contornada |
| 22 | Nenhum extrator de `.rar` encontrado | Repor `ferramentas\7z.exe` do kit (ou instalar 7-Zip) |
| 23 | Falha ao extrair o `.rar` | Conferir integridade do arquivo e espaco em disco |
| 24 | Conteudo esperado ausente no pacote extraido | Ajustar `innerExeMatch` / `driverInf` no manifesto |

## Instalacao (30+n)

| Codigo | Componente |
|:------:|------------|
| 30 | driver_cdm20824 (FTDI CDM) |
| 31 | ioterminal (IOT Multitool V50B) |
| 32 | license_idmonact (copia da licenca) |
| 33 | d2xx_runtime (copia da ftd2xx.dll) |

## Validacao (40+n)

| Codigo | Componente / situacao |
|:------:|----------------------|
| 40 | driver_cdm20824 — driver nao publicado ou `.sys` ausente |
| 41 | ioterminal — executavel ausente na pasta de instalacao |
| 42 | license_idmonact — licenca ausente na pasta do IOTerminal |
| 43 | Dispositivo FTDI com Code 52 (assinatura recusada) |
| 44 | Dispositivo FTDI com Code 43 (hardware/driver) |
| 45 | d2xx_runtime — ftd2xx.dll ausente na pasta do IOT ou em SysWOW64 |

Dispositivo FTDI ausente gera apenas `WARN`: a interface pode nao estar conectada e isso nao e falha de instalacao. Code 28 (`USB_FT232RL` em Outros dispositivos) tambem e `WARN`: rode o kit 0.3.9 e reconecte o USB.

## Bloqueio externo

| Codigo | Significado | Quando e atribuido |
|:------:|-------------|--------------------|
| 50 | Bloqueio por antivirus | AV de terceiros presente + falha de instalacao/extracao |
| 51 | Bloqueio por politica de dominio | `PartOfDomain = true` + falha de instalacao |

## Generico e rollback

| Codigo | Significado |
|:------:|-------------|
| 1 | Erro inesperado (excecao) ou rollback com falhas |
