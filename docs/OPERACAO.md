# Operacao — Instalador IOTerminal

Guia pratico de execucao, diagnostico e reversao.

## Pre-requisitos

| Item | Requisito |
|------|-----------|
| SO | Windows 10 22H2 / Windows 11, x64 |
| PowerShell | 5.1 (Desktop) |
| Privilegio | Administrador (UAC) |
| Extrator | Nenhuma instalacao previa: vem em `ferramentas\7z.exe` |
| Pacotes | Pasta `IOTERMINAL` com `DRIVERS`, `INSTALADOR` e `LICENCA` |

Nao e necessaria internet nem instalar nada antes: pacotes e extrator vem no kit.

O extrator embutido e verificado por SHA-256 (declarado em `bundledExtractor` no manifesto) antes de ser executado, porque roda elevado e os binarios do 7-Zip nao sao assinados pelo autor. Se `bundledExtractor` for retirado do manifesto, o instalador volta a procurar 7-Zip ou WinRAR instalado na maquina.

## Sintaxe

```
installer.ps1 [-ManifestPath <caminho>]
              [-PackageDir <caminho>]
              [-LogPath <caminho>]
              [-Force]
              [-DryRun]
              [-Rollback]
              [-Reinstall]
              [-SkipAvExclusion]
```

| Parametro | Default | Descricao |
|-----------|---------|-----------|
| `-ManifestPath` | `.\manifest.json` | Manifesto a usar |
| `-PackageDir` | `<kit>\IOTERMINAL` | Pasta raiz dos pacotes (sobrepoe `packageRoot`) |
| `-LogPath` | `C:\ProgramData\OficinaBinaria\ioterminal-setup` | Pasta do log |
| `-Force` | false | Reinstala mesmo quando `detect` e verdadeiro |
| `-DryRun` | false | Diagnostica sem alterar o sistema |
| `-Rollback` | false | Remove o que a ferramenta instalou |
| `-Reinstall` | false | Apaga a pasta do IOT e instala de novo (preserva o driver) |
| `-SkipAvExclusion` | false | Nao mexe nas exclusoes do Defender |

`-DryRun` nao combina com `-Rollback`, `-Force` nem `-Reinstall` (`exit 11`). `-Rollback` nao combina com `-Reinstall`.

O `scripts\iniciar-kit.cmd` chama o instalador com `-Reinstall`.

## Cenarios de uso

### 1. Diagnosticar antes de instalar

```powershell
.\installer.ps1 -DryRun
```

Mostra inventario, extrator disponivel, presenca de cada pacote e o que cada componente faria (`SKIPPED` ou `INSTALADO`).

### 2. Instalacao completa

```powershell
.\scripts\iniciar-kit.cmd
```

O `.cmd` pede o UAC e chama o `installer.ps1 -Reinstall`. Se o IOT ja estiver instalado, a pasta e apagada (o programa e fechado se estiver aberto) e a instalacao roda de novo. O driver FTDI publicado fica. Ordem: driver FTDI, IOT Multitool, biblioteca D2XX (`ftd2xx.dll` em `SysWOW64`), licenca IDMONACT.

### 3. Reinstalar um componente sem apagar a pasta

```powershell
.\installer.ps1 -Force
```

Para apagar o IOT e instalar do zero (o mesmo que o `iniciar-kit.cmd`):

```powershell
.\installer.ps1 -Reinstall
```

### 4. Reverter

```powershell
.\installer.ps1 -Rollback
```

Percorre `state.json` na ordem inversa: remove a licenca, a `ftd2xx.dll` da pasta do IOT, a pasta do IOT Multitool e despublica somente os drivers FTDI 2.8.24.0 que este kit instalou. A `ftd2xx.dll` em `SysWOW64` fica: e biblioteca de sistema e pode ser de outro CDM.

### 5. Instalar em outra pasta

Altere `installDir` do componente `ioterminal` no `manifest.json`. A licenca acompanha automaticamente, porque usa o token `{installDir}`.

## Log

- Linha: `[ISO-8601] [NIVEL] [COMPONENTE] mensagem`, niveis `INFO`, `WARN`, `ERROR`
- Arquivo: `<LogPath>\ioterminal-setup_<yyyyMMdd-HHmmss>.log`
- Conteudo: inventario, SHA-256 dos pacotes, comando executado e saida, resultado de cada predicado, sumario final

## Arquivo de estado

`C:\ProgramData\OficinaBinaria\ioterminal-setup\state.json`

Registra por componente: `id`, `packageVersion`, timestamp, `installedByTool`, metodo de reversao e a pasta de instalacao usada. Somente entradas com `installedByTool: true` sao revertidas.

## Solucao de problemas

| Sintoma | Codigo | Acao |
|---------|:------:|------|
| Fechou pedindo administrador | 10 | Use `scripts\iniciar-kit.cmd` e aceite o UAC |
| Reclama de extrator | 22 | Kit incompleto: reponha a pasta `ferramentas` |
| Pacote ausente | 20 | Nao renomeie as pastas dentro de `IOTERMINAL` |
| Hash divergente | 21 | Reponha o arquivo original do kit; se for o extrator, nao contorne |
| Driver nao valida | 40 | Veja no log as versoes FTDI presentes; rode com `-Force` |
| Themida: Cannot find FTD2XX.DLL | 45 | Kit antigo: rode o instalador novo (copia a DLL para `SysWOW64`) |
| PCA: driver nao pode ser carregado (ftdibus.sys) | 0 / 43 | Windows 11 recusa o kernel 2.08.24. Rode o kit 0.3.9 (publica o 2.12.36.20 WHQL) e reconecte a USB |
| USB_FT232RL em Outros dispositivos (Code 28) | 0 + WARN | Sem kernel FTDI. Rode o kit 0.3.9 e reconecte a interface |
| Licenca nao valida | 42 | Confira se a etapa `ioterminal` concluiu antes |
| Interface USB nao conectada | 0 + WARN | Normal: nao e falha de instalacao |

Tabela completa: [CODIGOS-SAIDA.md](CODIGOS-SAIDA.md)
