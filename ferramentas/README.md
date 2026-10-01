# ferramentas — extrator embutido

Os pacotes do kit sao `.rar` e o Windows nao le esse formato por linha de comando. Para o instalador nao depender de 7-Zip instalado na maquina do cliente, o extrator viaja dentro do kit.

| Arquivo | Origem | Funcao |
|---------|--------|--------|
| `7z.exe` | 7-Zip 26.00 (Igor Pavlov) | Extrator de linha de comando |
| `7z.dll` | 7-Zip 26.00 | Biblioteca de codecs exigida pelo `7z.exe` |
| `7-Zip-License.txt` | 7-Zip 26.00 | Licenca (LGPL e restricao unRAR) |

Os dois binarios precisam ficar na mesma pasta: o `7z.exe` carrega o `7z.dll` ao lado dele.

## Integridade

Os binarios do 7-Zip nao sao assinados pelo autor, e este executavel roda com privilegio administrativo. Por isso o `manifest.json` declara o SHA-256 dos dois arquivos em `bundledExtractor`, e o instalador confere os hashes antes de executar o extrator. Divergencia aborta com `exit 21`.

## Ao atualizar o 7-Zip

1. Baixe a versao nova em https://www.7-zip.org e instale.
2. Copie `7z.exe`, `7z.dll` e `License.txt` (renomeado para `7-Zip-License.txt`) para esta pasta.
3. Recalcule os hashes e atualize `bundledExtractor` no `manifest.json`:

```powershell
Get-FileHash .\ferramentas\7z.exe, .\ferramentas\7z.dll -Algorithm SHA256
```

4. Registre a versao nova neste arquivo e no `docs/CHANGELOG.md`.

Se `bundledExtractor` for removido do manifesto, o instalador volta a procurar 7-Zip ou WinRAR instalado na maquina e aborta com `exit 22` caso nao encontre.
