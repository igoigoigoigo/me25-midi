# ME-25 via USB: o que foi descoberto

Anotações dos testes feitos com uma BOSS ME-25 (driver BOSS 1.0.1, Windows 11).
Nada disso é documentado oficialmente; foi obtido por observação.

## Dispositivo

| Item | Valor |
|---|---|
| USB | `VID_0582` (Roland) `PID_0113`, classe vendor-specific (`FF`) — precisa do driver BOSS |
| Portas | áudio `IN/OUT (ME-25)` e MIDI `ME-25` (entrada e saída) |
| MIDI comum | **nenhum** — footswitches, CTL e pedal não geram Note/CC/PC |

## Identity Request

```
-> F0 7E 7F 06 01 F7
<- F0 7E 10 06 02 41 45 02 00 00 00 00 00 00 F7
```

Fabricante `41` (Roland), família `45 02`, device ID `10`.

## Roland RQ1 / DT1

Model ID de **3 bytes**: `00 00 45`. Pedido de dados (RQ1, comando `11`):

```
F0 41 10 00 00 45 11  a1 a2 a3 a4  s1 s2 s3 s4  sum  F7
```

`sum` = checksum Roland: `(128 - (soma de endereço+tamanho) % 128) % 128`.
A ME-25 parece ignorar o tamanho pedido e sempre responde com o bloco inteiro de um patch
(DT1, comando `12`, 141 bytes no total, 128 bytes de dados).

### Mapa de endereços

| Endereço | Conteúdo |
|---|---|
| `7F 00 00 00` … `7F 00 3B 00` | os **60 patches de usuário** (ordem da pedaleira; `PunkStrum` … `FreezeWonder` no padrão de fábrica) |
| `7F 01 00 00` … `7F 06 00 00` | 6 patches extras (StandardClean, TweedDrive, BluesLead, BrightCrunch, HeavyMetal, SuperHiGain) |
| `7F 7F 00 00` | **patch atual (temporário)** — muda quando você troca de patch ou liga/desliga efeitos |

Outros primeiros bytes (`00`–`7E`) não respondem.

### Bloco de patch

Os dados vêm como pares `00 vv` (um valor útil a cada 2 bytes). Índices abaixo contam a partir do
primeiro byte de dados (logo após o endereço, ou seja, `mensagem[11 + i]`):

| Índice | Significado |
|---|---|
| 65 | ON/OFF do **PEDAL FX** (pisar forte no pedal) |
| 85 | **SOLO** (0/1) |
| 97, 99, … 127 | **nome do patch**, 16 caracteres ASCII |

Outros índices são parâmetros dos efeitos (knobs), não mapeados aqui.

## Comportamento observado

- A ME-25 **não envia nada sozinha**: é preciso pedir (`RQ1`) para receber o estado.
- Pedir `7F 7F 00 00` a cada ~60–100 ms funciona bem e não atrapalha o som.
- Troca de patch: o bloco inteiro muda (nome incluso). Comparando o nome com a lista dos 60
  patches dá para saber se foi para cima ou para baixo (com volta de 60 → 1).
- Nomes repetidos (ex.: dois `NiceClean`) são resolvidos pelo patch mais próximo do anterior.
- **Posição do pedal de expressão não aparece em lugar nenhum**, nem com PEDAL FX ligado
  nem desligado (modo volume).
- Um potenciômetro com ruído pode gerar pequenas mudanças isoladas num parâmetro.
