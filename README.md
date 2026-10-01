# Instalador Automatizado IOTerminal

Prepara uma estacao Windows para operar o IOT Multitool, em ordem deterministica, com validacao e log diagnosticavel. Mesmo contrato do projeto PCMFlash (manifesto, predicados `detect`/`validate`, `state.json`, rollback e codigos de saida).

**Especificacao de referencia:** [IOTerminal-Escopo.md](IOTerminal-Escopo.md)

## Ordem de instalacao

| Ordem | ID | Componente | O que faz |
|:-----:|----|------------|-----------|
| 1 | `driver_cdm20824` | Driver FTDI | Publica `ftdibus.inf` e `ftdiport.inf` (2.08.24 no Windows 10 antigo; 2.12.36.20 WHQL no Windows 11) |
| 2 | `ioterminal` | IOT Multitool V50B | Extrai a aplicacao portatil para `C:\IOT_MULTITOOLV50B` |
| 3 | `d2xx_runtime` | Biblioteca D2XX | Copia `ftd2xx.dll` para a pasta do IOT e para `SysWOW64` |
| 4 | `license_idmonact` | Licenca IDMONACT | Copia a pasta `IDMONACT` para dentro da pasta do IOT Multitool |

A ordem nao pode ser violada: a DLL e a licenca dependem da pasta criada na etapa 2. O `pnputil` publica so o driver de kernel; sem a `ftd2xx.dll` o IOT Multitool (protegido pelo Themida) recusa abrir com "Cannot find FTD2XX.DLL".

## Arquivos do projeto

| Arquivo | Funcao |
|---------|--------|
| `installer.ps1` | Script principal (PowerShell 5.1) |
| `manifest.json` | Pacotes, predicados e parametros |
| `manifest.schema.json` | Esquema JSON do manifesto |
| `IOTERMINAL/` | Pacotes do kit (`DRIVERS`, `INSTALADOR`, `LICENCA`) |
| `ferramentas/` | Extrator `.rar` embutido (7-Zip), verificado por hash |
| `scripts/iniciar-kit.cmd` | Atalho que eleva com UAC e executa o instalador |
| `scripts/preparar-kit.ps1` | Monta a pasta/ZIP do kit para levar ao cliente |
| `scripts/atualizar-zip.ps1` | Mantem o `ioterminal-kit.zip` da raiz sempre atualizado |
| `scripts/enviar-para-vm.ps1` | Envia o kit para a VM de teste e traz os logs de volta |
| `ioterminal-kit.zip` | Kit pronto para levar a VM ou ao cliente (regerado automaticamente) |
| `.cursor/hooks.json` | Hook que dispara a atualizacao do ZIP apos edicoes |
| `vm/` | Scripts antigos de Hyper-V, fora do fluxo de automacao |

## Inicio rapido

Requisitos: Windows 10/11 x64, PowerShell 5.1 e administrador. Nada mais precisa ser instalado antes — o extrator dos pacotes vem no kit.

```powershell
# Diagnosticar sem alterar nada
.\installer.ps1 -DryRun

# Instalar (ou clicar duas vezes em scripts\iniciar-kit.cmd)
# O atalho usa -Reinstall: apaga o IOT ja instalado e instala de novo
.\installer.ps1 -Reinstall

# Reinstalar um componente ja presente, sem apagar a pasta
.\installer.ps1 -Force

# Reverter o que a ferramenta instalou
.\installer.ps1 -Rollback
```

Log: `C:\ProgramData\OficinaBinaria\ioterminal-setup\ioterminal-setup_<timestamp>.log`

## Kit pronto (`ioterminal-kit.zip`)

O `ioterminal-kit.zip` da raiz e o que se leva para a VM ou para o cliente: contem o instalador, o manifesto, o extrator embutido, os pacotes e as instrucoes.

Ele se mantem atualizado sozinho. O hook `.cursor/hooks.json` chama `scripts/atualizar-zip.ps1` apos cada edicao de arquivo e ao fim de cada tarefa do agente; o script compara a data do ZIP com a dos arquivos que entram nele e so remonta quando algo mudou (caso contrario termina em fracao de segundo). A montagem continua sendo feita pelo `preparar-kit.ps1`, em pasta temporaria, para nao deixar copia duplicada dentro do projeto.

```powershell
# Forcar a regeneracao (ou rodar depois de editar arquivos fora do Cursor)
.\scripts\atualizar-zip.ps1 -Forcar
```

Resultado de cada execucao fica em `.cursor\atualizar-zip.log`. Uma falha na regeneracao nunca interrompe o trabalho no editor: o hook registra o erro e devolve sucesso. Por isso, antes de levar o kit para a VM, vale conferir a data do ZIP.

## Teste na VM

Os comandos abaixo sao relativos a pasta do projeto: entre nela primeiro, senao o PowerShell nao encontra os scripts.

```powershell
cd 'C:\Users\bina1\Documents\Automatização softwares\IOTerminal'

Start-VM -Name 'Teste IOTerminal'          # se estiver desligada
.\scripts\enviar-para-vm.ps1 -Extrair     # atualiza o ZIP, envia e extrai na VM
# rodar iniciar-kit.cmd dentro da VM, como administrador
.\scripts\enviar-para-vm.ps1 -TrazerLog   # traz o log do instalador para logs-vm\
```

Para usar outra VM: `-Nome 'Nome da VM'`. O padrao e `Teste IOTerminal`.

O transporte usa PowerShell Direct, que fala com a VM pelo barramento do Hyper-V: dispensa rede, IP e compartilhamento, e permite trazer o log de volta. Exige a VM ligada e uma conta **local** de administrador **com senha** — conta Microsoft e senha em branco nao autenticam. Se a sessao direta falhar, o script cai para `Copy-VMFile`, que envia mas nao retorna arquivos (precisa da Interface de Servico de Convidado habilitada na VM).

Assim que o Windows da VM estiver instalado, tire o checkpoint de referencia para repetir o teste sempre do mesmo ponto:

```powershell
Checkpoint-VM -Name 'Teste IOTerminal' -SnapshotName 'Windows limpo'
```

O `-Rollback` do instalador desfaz o que ele mesmo fez; o checkpoint e o que devolve a maquina ao estado limpo.

O Hyper-V nao redireciona interface USB comum para dentro da VM. Por isso o teste em VM cobre a publicacao do driver, a extracao da aplicacao e a licenca, enquanto conferir o dispositivo exige maquina fisica de bancada (detalhes em [IOTerminal-Escopo.md](IOTerminal-Escopo.md), secoes 8.4 e 12).

## Documentacao

| Documento | Conteudo |
|-----------|----------|
| [IOTerminal-Escopo.md](IOTerminal-Escopo.md) | Especificacao tecnica: requisitos, fluxo, criterios de aceitacao e lacunas |
| [docs/OPERACAO.md](docs/OPERACAO.md) | Parametros, cenarios de uso, log e rollback |
| [docs/MANIFESTO.md](docs/MANIFESTO.md) | Contrato do `manifest.json` |
| [docs/CODIGOS-SAIDA.md](docs/CODIGOS-SAIDA.md) | Codigos de saida e diagnostico |
| [docs/CHANGELOG.md](docs/CHANGELOG.md) | Historico de alteracoes |

## Decisoes tecnicas relevantes

**O driver e publicado por `pnputil`, nao pelo `CDM20824_Setup.exe`.** O executavel do kit e um empacotador nao assinado e com metadados de outro fabricante ("Synaptics Pointing Device Driver"). O conteudo dele, porem, e o pacote FTDI legitimo: `ftdibus.cat` e `ftdiport.cat` assinados pelo *Microsoft Windows Hardware Compatibility Publisher* e `ftdibus.sys` assinado pela FTDI. O instalador extrai esse conteudo e publica os `.inf` diretamente, o que evita executar o empacotador e torna o resultado verificavel por `pnputil /enum-drivers`.

**No Windows 11 o kernel 2.08.24 nao e publicado.** Esse `ftdibus.sys` e de 2012 e o Windows 11 recusa carrega-lo. Um PC limpo tambem nao traz FTDI 2.12 de fabrica: a interface fica em Outros dispositivos como `USB_FT232RL` (Code 28). Por isso o kit publica o CDM 2.12.36.20 WHQL (`DRIVERS\CDM21236.zip`) e remove o 2.08.24 se ainda estiver no DriverStore. Desconecte e reconecte a interface depois. Em Windows 10 antigo (build abaixo de 22000, sem HVCI) o kernel 2.08.24 do kit original ainda e publicado.

**O extrator viaja no kit e e conferido por hash.** Os pacotes sao `.rar`, formato que o Windows nao le por linha de comando, e exigir 7-Zip instalado quebraria a instalacao em maquina limpa. Como os binarios do 7-Zip nao sao assinados pelo autor e o extrator roda elevado, o `manifest.json` declara o SHA-256 do `7z.exe` e do `7z.dll`; divergencia aborta com `exit 21` antes de qualquer execucao.

**O IOT Multitool e 32 bits e precisa da `ftd2xx.dll` em dois lugares.** O `pnputil` publica o driver de kernel, mas nao instala a biblioteca de usuario D2XX. O Themida, que protege o executavel, chama `GetSystemDirectory()` e em um processo 32 bits isso aponta para `SysWOW64`, nao para a pasta do programa. Por isso o instalador copia `i386\ftd2xx.dll` (v3.02.07, do pacote CDM 2.08.24) para `{installDir}` e para `{syswow64}`. Sem a copia em `SysWOW64`, um PC limpo abre o IOT e cai em "Cannot find 'FTD2XX.DLL'".

**O IOT Multitool e portatil.** O `.rar` nao tem instalador: contem `iot_MULTITOOLv50B.exe`, `img\` e `files\`. Por isso a etapa 2 e uma extracao para `installDir`, e o executavel e marcado para abrir sempre como administrador.
