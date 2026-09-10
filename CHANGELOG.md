# Changelog

## 0.4.0 — 2026-09-10

- O app e o componente auxiliar passam a ser assinados com Developer ID, com hardened runtime, e a distribuição é notarizada pela Apple: não é mais preciso contornar o Gatekeeper na primeira abertura.
- O componente auxiliar agora verifica a assinatura de quem se conecta a ele, em vez de confiar no identificador declarado no bundle do chamador.
- Adiciona `scripts/release.sh`, que assina, notariza e faz staple do app e do DMG.
- Ao abrir depois de instalado, o Taurine oferece ejetar a imagem de disco de instalação, se ela ainda estiver montada.
- Nova opção **Mostrar o Taurine no Dock**, desativada por padrão. Com ela ligada, clicar no ícone do Dock abre as Preferências.
- Novo ícone do app e novos ícones da barra de menus.

## 0.3.0 — 2026-09-07

- Substitui o uso direto de `pmset` (senha a cada ativação ou regra em `sudoers.d`) por um componente auxiliar privilegiado instalado uma única vez.
- O componente restaura o repouso quando o Taurine fecha, falha, é encerrado à força ou o Mac reinicia, inclusive após desligamento por bateria.
- O componente remove-se sozinho no boot seguinte se o app tiver sido apagado.
- Remove a opção de autorização permanente via `sudoers.d`; a regra antiga é apagada ao instalar o componente.
- Adiciona `scripts/make-dmg.sh` para gerar a imagem de distribuição.
- O componente auxiliar é instalado apenas pelo botão em Preferências; o menu apenas leva até lá.
- Chamadas ao componente têm limite de 10 s; se ele não responder, o app informa o erro em vez de travar.
- A remoção do componente restaura o repouso antes de apagar os arquivos.
- Novo ícone do app.

## 0.2.3 — 2026-09-07

- Adiciona borda e sanitização de dígitos ao campo de porcentagem.
- Permite desligar a proteção por bateria em um toggle persistente, ligado por padrão.
- Torna a autorização permanente opcional, com senha por alteração quando não configurada e sem repetir prompts nas tentativas automáticas.

## 0.2.2 — 2026-09-07

- Remove a janela Settings vazia e mantém uma única janela Preferences, também ao reabrir o app ou usar ⌘,.

## 0.2.1 — 2026-09-07

- Compacta a proteção da bateria em uma linha: legenda à esquerda, slider sem marcas e porcentagem editável à direita.
- Mantém o ajuste de um em um e amplia a faixa para 1–100%, preservando o padrão de 60%.
- Identifica a carga atual como “Current battery” e exibe ícones nativos que acompanham a carga e o limite selecionado.

## 0.2.0 — 2026-09-07

- Acrescenta slider de proteção da bateria (5–100%), com padrão de 60%, nas Preferências.
- Restaura o repouso ao atingir o limite usando bateria, inclusive ao desconectar a tomada; impede ativação abaixo do limite e não religa automaticamente.
- Monitora bateria via IOKit e reaplica a política ao mudar o limite, acordar ou reabrir o app.
- Acrescenta autorização única e removível, limitada aos dois comandos exatos de `pmset`, para a conta atual.
- Executa toggles e desligamentos automáticos sem prompts de senha ou dependência de credenciais em cache.
- Mantém recuperação visível e novas tentativas espaçadas quando o corte por bateria falha.

## 0.1.0 — 2026-09-07

- Adapta a base fornecida do Caffeine para Taurine, com identidade própria e ícones de latinha.
- Usa os PNGs template fornecidos (44×44 px) em um item de 22 pt: fechado quando desativado e aberto quando ativado, com coloração automática pelo macOS.
- Acrescenta `pmset -a disablesleep 1/0` com autorização nativa de administrador.
- Verifica o estado real antes de apresentar sucesso e mantém solicitações IOKit contínuas para sistema e tela.
- Trata cancelamento, falhas parciais, encerramento, recuperação ao reabrir e alterações externas.
- Preserva durações, preferências e simulação opcional de atividade; temporizadores dependem de autorização ao terminar.
- Remove a opção incompatível de desativar ao repousar manualmente e o atualizador vinculado ao Caffeine.
- Inclui build local sem dependências e testes do ciclo de energia sem alterações privilegiadas.
