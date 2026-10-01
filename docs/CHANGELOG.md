# Changelog — Instalador IOTerminal

## v0.3.9 — 2026-10-01

No PC limpo o IOT abriu, mas a interface ficou em Outros dispositivos como `USB_FT232RL` (Code 28: sem driver). O kit 0.3.6/0.3.8 so tirava o kernel 2.08.24 e assumia que o Windows 11 ja tinha FTDI 2.12 de fabrica. Em maquina limpa isso nao existe.

### Alterado

- Pacote `IOTERMINAL/DRIVERS/CDM21236.zip`: kernel WHQL 2.12.36.20 (`ftdibus.inf` / `ftdiport.inf`, assinatura Microsoft).
- No Windows 11 o instalador publica esse 2.12.36.20 depois de remover o 2.08.24.
- Detect/validate no Win11 exigem kernel 2.12+ presente, nao so a ausencia do 2.08.24.
- O log grava `Revisao do kit: 0.3.9`.

### Como retestar

ZIP novo, `iniciar-kit.cmd`. No Gerenciador de dispositivos o item deve sair de Outros dispositivos e virar USB Serial Converter (FTDI). Depois desconecte, reconecte e abra o IOT.

## v0.3.8 — 2026-10-01

O exit 1 de `.Count` continuou no PC limpo (15:25) mesmo com `List[string]`. Causa: o PowerShell **enumera** a List no `return`. Com um unico `oemN.inf` o caller recebe uma string, e StrictMode recusa `.Count`.

### Alterado

- `Get-PublishedDriverBlocks` e `Get-PublishedDriverNames` preenchem uma `List[string]` recebida em `-Result` (`AllowEmptyCollection`). Nada de colecao no `return`: o PowerShell nao pode mais transformar 1 `oem` em string.
- O log passa a gravar `Revisao do kit: 0.3.8` no inicio. Se essa linha nao aparecer, o ZIP na area de trabalho ainda e o antigo.

## v0.3.7 — 2026-10-01

Correcao do `exit 1` no PC limpo ao remover o kernel 2.08.24: com StrictMode, um unico `oemN.inf` deixava de ser array e `.Count` quebrava em `Invoke-ComponentUninstall`. Listas de drivers publicados passaram a ser `List[string]`, que sempre tem `Count`.

## v0.3.6 — 2026-10-01

O IOT passou a abrir no PC limpo, mas ao conectar a interface o Windows recusou o `ftdibus.sys` ("Uma configuracao de seguranca esta impedindo o carregamento deste driver").

### Causa

O kit publicava o kernel FTDI 2.08.24 (2012). O Windows 11 nao carrega esse `.sys` (assinatura antiga / Integridade de memoria). A interface ligava nesse driver recem-publicado em vez do FTDI 2.12.x de fabrica.

### Alterado

- `skipKernelBuild: 22000` no manifesto: em Windows 11 (ou com HVCI) o instalador **nao** publica `ftdibus.inf` / `ftdiport.inf` do kit.
- Se o 2.08.24 ja estiver no DriverStore, ele e removido (`pnputil /delete-driver` + `/scan-devices`). A `ftd2xx.dll` continua sendo copiada do mesmo pacote.
- `-Reinstall` (o `iniciar-kit.cmd`) tambem retira o kernel 2.08.24.

### Como retestar

ZIP novo, `iniciar-kit.cmd`, **desconectar e reconectar** a interface. O aviso do Auxiliar de Compatibilidade sobre `ftdibus.sys` nao deve voltar.

## v0.3.5 — 2026-10-01

O `iniciar-kit.cmd` passou a reinstalar o IOT do zero em toda execucao.

### Alterado

- `installer.ps1 -Reinstall`: fecha processos na pasta de instalacao (incluindo o aviso do Themida), apaga `{installDir}` (aplicacao, licenca e `ftd2xx.dll` local), remove o atalho da area de trabalho e reinstala. O driver FTDI publicado e a `ftd2xx.dll` de `SysWOW64` sao preservados. Recusa apagar `C:\`, `Windows` ou `Program Files`.
- `scripts/iniciar-kit.cmd` chama o instalador com `-Reinstall`. Rodar o atalho de novo depois de um teste ou do erro Themida e o caminho certo: nao depende de `SKIPPED`.

### Como retestar

No PC limpo, extraia o ZIP novo e clique duas vezes em `iniciar-kit.cmd`. Se o IOT ja estiver la, ele e apagado e instalado de novo.

## v0.3.4 — 2026-10-01

Correcao do erro Themida "Cannot find 'FTD2XX.DLL'" em PC limpo.

### Causa

O IOT Multitool e 32 bits e protegido pelo Themida. O `pnputil` publica so o driver de kernel (`ftdibus.sys` / `ftser2k.sys`). A biblioteca de usuario `i386\ftd2xx.dll` (D2XX 3.02.07) fica no pacote CDM e o setup oficial a copia para `SysWOW64`. Sem isso, o Themida resolve `FTD2XX.DLL` via `GetSystemDirectory()` (que no processo 32 bits e `SysWOW64`) e recusa abrir. Copiar a DLL so para a pasta do programa nao basta.

### Alterado

- `d2xx_runtime` agora copia `i386\ftd2xx.dll` para `{installDir}` **e** `{syswow64}`. O `detect`/`validate` exige os dois caminhos, para uma instalacao anterior so na pasta do IOT nao ser marcada `SKIPPED`.
- Tokens `{syswow64}` e `{system32}` em `Expand-PathToken`. Em Windows 32 bits, `{syswow64}` cai no `System32`.
- Copia para `SysWOW64` so se o arquivo ainda nao existir: nao rebaixa uma D2XX mais nova (ex.: 3.02.12 de outro CDM). O rollback remove so a copia em `{installDir}`.
- Documentacao (README, escopo §3/§5/§8.2/§8.5, manifesto, codigos 33 e 45, PASSO-A-PASSO) alinhada com o quarto componente.

### Como retestar

Levar o `ioterminal-kit.zip` novo. Se o IOT ja estava na pasta, rode o instalador de novo sem `-Force`: o `detect` da DLL em `SysWOW64` falha e a copia e refeita.

## v0.3.3 — 2026-09-29

Infraestrutura de teste e coerencia da documentacao. Nenhuma alteracao no `installer.ps1`, no `manifest.json` ou nos pacotes.

### Alterado

- VM padrao do `enviar-para-vm.ps1` passou de `VM-Win11` para `Teste IOTerminal`.
- `README.md`, secao "Teste na VM": exemplos apontando para a `Teste IOTerminal`, comando do checkpoint `Windows limpo` (criado depois da instalacao do Windows, nao antes), exigencia de conta local de administrador com senha para o PowerShell Direct e nota de que a interface USB nao chega na VM.
- `IOTerminal-Escopo.md`: registrada a limitacao de USB no Hyper-V em §8.4 e §12, com o criterio A1 desdobrado entre o que a VM valida e o que exige bancada fisica.

### Ambiente de teste

- A `VM-Win11` e o checkpoint `Windows limpo` foram perdidos junto com a particao que os hospedava. O log `Hyper-V-VMMS-Admin` de 28/09 08:33 registra `'VM-Win11' nao pode acessar a pasta de dados da maquina virtual`; nao existe nenhum arquivo `VM-Win11*` em C: nem em D:; o disco unico (SSD 2 TB) tem C: com 414 GB, um D: vazio de 50 GB e cerca de 1,4 TB nao alocados, e o registro do Windows mostra que existiram volumes E: e F:. Nao ha disco desconectado a reconectar.
- Removidas as quatro entradas orfas de cache da `VM-Win11` (`122B17F4-...`, arquivo e pasta, em `Virtual Machines Cache`; `A3C5473E-...`, arquivo e pasta, em `Snapshots Cache`), que faziam qualquer `Get-VM` falhar com "objeto nao encontrado" no host. Backup em `%TEMP%\diag-vm\backup-cache`. Foi preciso parar o servico `vmms`: com ele no ar os arquivos ficam travados, e o `Remove-VM` nao resolve porque o Hyper-V nao consegue nem resolver a VM.
- VM `Teste IOTerminal` preparada para a instalacao do Windows 11: **TPM virtual habilitado** (estava desabilitado, e sem ele o instalador recusa a maquina), checkpoint automatico removido para a VM voltar ao VHDX base em vez de rodar num `.avhdx` diferencial, e checkpoints automaticos desabilitados. Secure Boot ja estava On com template MicrosoftWindows, ISO do Win11 25H2 primeira na ordem de boot, 8 vCPU e 7,8 GB de RAM dinamica.
- Adaptador de rede da `Teste IOTerminal` desconectado de proposito: sem internet o OOBE do Windows 11 permite criar conta local, exigida pelo PowerShell Direct, e a primeira rodada do teste mede o driver do kit sem interferencia do Windows Update. Reconectar depois com `Connect-VMNetworkAdapter -VMName 'Teste IOTerminal' -SwitchName 'vSwitch-Externo'` e o que exercita o criterio A8.

## v0.3.2 — 2026-09-21

### Adicionado

- `scripts/enviar-para-vm.ps1`: envia o kit para a VM de teste por PowerShell Direct, opcionalmente extrai (`-Extrair`) e traz os logs do instalador de volta (`-TrazerLog`, salvos em `logs-vm\`). Reaproveita o `atualizar-zip.ps1`, entao a VM sempre recebe a versao atual do projeto. Sem PowerShell Direct, cai para `Copy-VMFile`.
- Secao "Teste na VM" no `README.md`, incluindo a recomendacao de checkpoint antes do primeiro teste.

### Alterado

- VM padrao do `enviar-para-vm.ps1` passou a ser `VM-Win11`, a que esta de fato em uso (a `Teste IOTerminal` nunca teve Windows instalado: VHDX com 0,04 GB). **Superado:** a `VM-Win11` deixou de existir em 29/09 e o padrao voltou para `Teste IOTerminal` (ver v0.3.3).
- VM `Teste IOTerminal`: habilitada a Interface de Servico de Convidado (estava desabilitada), necessaria para o `Copy-VMFile` de reserva. A `VM-Win11` ja estava com o servico habilitado.
- `README.md`: o exemplo de teste na VM agora comeca com `cd` para a pasta do projeto, porque os caminhos `.\scripts\...` sao relativos a pasta atual.

### Decisoes

- Transporte por PowerShell Direct em vez de rede ou compartilhamento: dispensa IP, credencial de rede e configuracao dentro da VM, e e o unico caminho simples que traz o log de volta na mesma ferramenta.

## v0.3.1 — 2026-09-21

### Adicionado

- `ioterminal-kit.zip` versionado na raiz do projeto: o kit pronto para levar a VM ou ao cliente.
- `scripts/atualizar-zip.ps1`: compara a data do ZIP com a dos arquivos que entram nele (instalador, manifesto, esquema, `iniciar-kit.cmd`, `README.md`, `PASSO-A-PASSO.txt`, `ferramentas\` e `IOTERMINAL\`) e remonta somente quando algo mudou. A montagem continua no `preparar-kit.ps1`, chamado em pasta temporaria, para nao duplicar logica nem deixar copia do kit dentro do projeto.
- `.cursor/hooks.json`: hooks `afterFileEdit` e `stop` disparando a atualizacao do ZIP.

### Decisoes

- O hook falha aberto: erro na regeneracao e registrado em `.cursor\atualizar-zip.log` e devolve sucesso, para nunca travar a edicao. A contrapartida e conferir a data do ZIP antes de levar o kit para a VM.
- O modo `-Hook` silencia a saida do `preparar-kit.ps1` e emite apenas `{}` no stdout, porque o Cursor espera JSON nesse canal.
- Dois eventos em vez de um: `afterFileEdit` cobre as edicoes durante o trabalho e `stop` garante o ZIP consistente ao fim da tarefa. Como o script e no-op quando nada mudou, o custo do evento extra e irrelevante.

### Testado

- ZIP atualizado: no-op. Arquivo alterado: regeneracao em ~1,5 s. Comando exato do hook: `stdout` `{}`, `exit 0`, nos dois casos.
- ZIP regenerado conferido: 29 entradas, os 2 `.rar`, o extrator e as 15 licencas `.bin`.

## v0.3 — 2026-09-16

Preparacao para o teste em VM limpa: eliminada a dependencia de 7-Zip instalado e retirado do kit o binario de origem duvidosa.

### Adicionado

- `ferramentas\` com o extrator embutido (7-Zip 26.00: `7z.exe`, `7z.dll`, licenca) e `ferramentas/README.md` com o procedimento de atualizacao.
- `bundledExtractor` no `manifest.json` e no esquema: caminho e SHA-256 do extrator e da biblioteca de codecs.
- `Get-BundledArchiveTool` no `installer.ps1`: o extrator do kit tem prioridade sobre qualquer 7-Zip/WinRAR instalado e so e executado se os hashes conferirem (`exit 21` caso contrario). Motivo: os binarios do 7-Zip nao sao assinados pelo autor e o extrator roda elevado.
- Copia da pasta `ferramentas` em `scripts/preparar-kit.ps1`.

### Removido

- `IOTERMINAL\DRIVERS\CDM20824_Setup\CDM20824_Setup.exe` (2,4 MB): empacotador nao assinado, com metadados de outro fabricante, que o instalador nunca executava. O driver continua vindo do `.rar` do kit.

### Testado nesta maquina

- Instalacao das etapas 2 e 3 usando **somente** o extrator do kit: `exit 0`, log confirmando `ferramentas\7z.exe` (criterio A16).
- `7z.exe` do kit alterado em 1 byte: `exit 21` antes de qualquer execucao (criterio A15).
- Kit gerado: 10,1 MB (era 10,7 MB com o empacotador removido).

### Impacto na documentacao

- Escopo: §2 (sem dependencia externa), §5, §7.1, nova §8.6 normativa, §12 com duas lacunas fechadas, §13 com A12 revisto e A15/A16 novos.
- `PASSO-A-PASSO.txt`: passo de instalar 7-Zip eliminado.

## v0.2.1 — 2026-09-16

### Adicionado

- `IOTerminal-Escopo.md`: especificacao tecnica normativa espelhando o `PCMFlash-Escopo.md`, com ambiente alvo, contrato do manifesto, fluxo, codigos de saida, estado/reversao, lacunas conhecidas (§12), matriz de aceitacao A1–A14 (§13) e fases.
- Referencias ao escopo no `README.md`.

### Registrado como decisao normativa no escopo

- §8.2: driver publicado por `pnputil`, nunca executando o empacotador do fabricante.
- §8.3: predicado de driver compara versao; rollback restrito as versoes do kit.
- §8.7: licenca copiada como pasta, com backup obrigatorio de licenca preexistente.
- §8.1: proibido usar `Start-Process -PassThru` para capturar `ExitCode`.

## v0.2 — 2026-09-16

Primeira versao funcional, alinhada ao contrato do projeto PCMFlash.

### Adicionado

- `installer.ps1` com fluxo deterministico de tres componentes, inventario de ambiente, motor de predicados (`file`, `dir`, `driver`, `registry`, `service`), `state.json`, rollback, `-DryRun`, `-Force` e exclusoes do Defender.
- `manifest.json` preenchido com hashes SHA-256 reais dos pacotes e predicados verificados na maquina.
- `manifest.schema.json` com o contrato do manifesto.
- `scripts/iniciar-kit.cmd` (eleva com UAC) e `scripts/preparar-kit.ps1` (monta kit e ZIP).
- Documentacao: `README.md`, `docs/OPERACAO.md`, `docs/MANIFESTO.md`, `docs/CODIGOS-SAIDA.md`.

### Decisoes

- O driver FTDI passou a ser publicado por `pnputil /add-driver` a partir do conteudo extraido, em vez de executar `CDM20824_Setup.exe`. O executavel do kit nao e assinado e traz metadados de outro fabricante; o conteudo interno, verificado, e o pacote FTDI WHQL legitimo.
- Predicados de driver comparam a versao (`2.8.24.0`). Sem isso, os drivers FTDI 2.12.x que o Windows traz de fabrica fariam o instalador marcar `SKIPPED` sem instalar o driver do kit. O rollback usa o mesmo filtro para nao remover drivers de terceiros.
- O IOT Multitool e tratado como aplicacao portatil (extracao para `installDir`), porque o `.rar` nao contem instalador.
- A licenca IDMONACT e copiada como pasta completa (subpastas por serial), com backup automatico de uma licenca preexistente.
- `System.Diagnostics.Process` substituiu `Start-Process -PassThru`: este ultimo retornava `ExitCode` vazio, o que fazia extracoes bem-sucedidas serem tratadas como falha.

### Testado nesta maquina (Windows 11 Pro, build 26200)

- `-DryRun`: `exit 0`, relatorio completo, nenhuma alteracao.
- Instalacao das etapas 2 e 3 em pasta temporaria: `exit 0`, 15 arquivos de licenca copiados, `validate` OK.
- Segunda execucao: `exit 0` com `SKIPPED` em ambos os componentes (idempotencia).
- `-Rollback`: `exit 0`, remocao na ordem inversa.
- Sem elevacao: `exit 10` sem alterar o sistema.

### Pendente

- Validar a etapa 1 (driver) em maquina limpa, com a interface USB conectada.
- Empacotamento em `.exe` assinado (equivalente a Fase 5 do PCMFlash).
