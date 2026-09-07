# Taurine

App para a barra de menus do macOS, baseado no [Caffeine](https://github.com/domzilla/Caffeine), com bloqueio adicional de repouso pelo `pmset`.

Ao **ligar**, mantém o sistema e a tela acordados com IOKit e executa, com autorização de administrador:

```sh
sudo pmset -a disablesleep 1
```

Ao **desligar**, restaura o repouso e libera as solicitações de energia:

```sh
sudo pmset -a disablesleep 0
```

Nas Preferências, **Autorizar uma vez…** abre a janela de administrador do macOS para instalar uma regra restrita em `/private/etc/sudoers.d/taurine-<UID>`. Ela libera somente esses dois comandos exatos, como root, para a conta atual. Não há curingas nem autorização para outros comandos ou argumentos. Qualquer programa dessa conta também poderá executar esses dois comandos. Nenhuma senha é armazenada.

Após essa configuração, o app usa `sudo -n -k`: nunca abre um prompt nos toggles, temporizadores ou cortes por bateria e não depende do cache de senhas. **Remover…** primeiro restaura o repouso e depois remove apenas essa regra, com autorização de administrador.

## Usar

Abra `build/Taurine.app`. Requer macOS 14.6 ou posterior.

- Clique na latinha para ligar/desligar.
- Clique com o botão direito, Control ou Command para abrir o menu.
- Use **Ativar por** para escolher uma duração; as preferências definem a duração padrão e a ativação ao abrir.
- A opção herdada **Manter apps ativos** simula atividade e pode exigir permissão de Acessibilidade; fica desativada por padrão.
- Um triângulo indica que o repouso precisa ser restaurado ou que não foi possível confirmar seu estado. Use **Restaurar repouso…**.

## Autorização e recuperação

`disablesleep` é uma configuração **global e persistente**, inclusive para bateria e tomada. O desligamento aplica **0**, conforme a proposta do Taurine; não restaura um valor anterior diferente de 0.

A autorização permanente é **opcional**. Sem ela, cada alteração de repouso solicita a senha de administrador, inclusive o desligamento por temporizador ou bateria: o bloqueio permanece até a aprovação. Cancelar um corte por bateria não abre novos prompts nas tentativas automáticas; use **Restore sleep** para tentar novamente manualmente. Com autorização permanente, o término do temporizador e o corte por bateria restauram o repouso sem interação. Caso a permissão seja revogada ou o comando falhe, o app apresenta o estado de recuperação; não presume que o repouso foi restaurado.

### Proteção da bateria

O toggle **Battery protection**, ligado por padrão, permite desativar apenas o corte por bateria; o temporizador continua funcionando. Religar o toggle aplica o limite imediatamente. O slider nas Preferências ajusta o limite entre **1% e 100%**, com padrão **60%**. O campo com borda ao lado do slider aceita somente dígitos ASCII e limita o valor a 1–100; Enter ou sair do campo aplica o número, limitado a 1–100. Escape cancela a edição. Os ícones usam os níveis de bateria nativos do macOS. Enquanto o Mac estiver usando bateria, o bloqueio de repouso é desligado quando a carga for **menor ou igual** ao limite. Na tomada, esse corte não se aplica; desconectar o carregador abaixo do limite provoca a restauração. Não é possível iniciar uma sessão já abaixo do limite na bateria, e o Taurine não se religa automaticamente depois de carregar.

A leitura usa IOKit, com notificações de mudanças e conferência adicional a cada cinco segundos. Mudar o slider aplica a nova política à sessão atual. Se a leitura falhar, uma sessão ativa é encerrada por precaução; Macs sem bateria interna usam apenas o temporizador. Se a restauração por bateria falhar, há novas tentativas a cada 30 segundos sem repetir alertas. A proteção depende de o Taurine estar aberto e responsivo; não há serviço independente vigiando outros programas.

Ao sair normalmente, o Taurine verifica e restaura o repouso antes de encerrar. Se a restauração falhar ou for cancelada, permanece aberto. Após encerramento forçado, falha do processo ou desligamento abrupto, o valor pode continuar em 1: reabra o Taurine e escolha **Restaurar repouso…**, ou execute o comando com valor 0 acima. Não há serviço privilegiado para recuperação enquanto o app estiver fechado.

O estado é consultado ao abrir, depois de cada alteração e periodicamente durante a execução. Um marcador em `~/Library/Application Support/Taurine/pending-session` registra sessões pendentes. A leitura atual do `pmset` é a fonte de verdade, inclusive quando outro programa alterou a configuração. Evite usar outros utilitários para mudar `disablesleep` durante uma sessão. Múltiplas cópias do Taurine na mesma conta são impedidas de operar simultaneamente.

O bloqueio de repouso não garante operação com a tampa fechada em todos os modelos e condições. A antiga opção de desativar ao repousar manualmente foi retirada porque conflita com o bloqueio global solicitado.

## Compilar

Sem dependências externas. Com o compilador Swift 6.2 ou posterior e o SDK do macOS instalados:

```sh
./scripts/build.sh
open build/Taurine.app
```

O script compila para a arquitetura do Mac e gera um aplicativo com assinatura local ad hoc. A distribuição pública ainda exige assinatura Developer ID e notarização.

Também é possível abrir `src/Taurine.xcodeproj` no Xcode ou usar `./scripts/build-xcode.sh`. O build direto permite trabalhar mesmo se componentes opcionais da instalação do Xcode estiverem inconsistentes.

```sh
swift test
```

Os testes usam implementações simuladas de autorização, bateria e energia: cobrem ativação, desligamento, cancelamento, resposta incompleta, falha de leitura, recuperação, temporizadores, operações simultâneas persistência, limite exato de bateria, carregador e falhas de restauração. A sintaxe da regra é validada com `visudo`. Não executam alterações privilegiadas no Mac. A validação manual de ligar/desligar requer autorizar as duas operações e confirmar `SleepDisabled` com `pmset -g`.

## Origem

Adaptado do `Caffeine-master.zip` fornecido pelo usuário, revisão `b7f4c38a9782c664397e413d89d5bcf260182897`. Preserva a base SwiftUI/AppKit, preferências, durações, opção de simular atividade e traduções herdadas. Os novos controles estão traduzidos para inglês e português; outros idiomas usam inglês nos novos textos.

O atualizador Sparkle e o feed do Caffeine foram removidos, assim como a dependência não utilizada DZFoundation. O Taurine tem identificação, preferências e recursos próprios. As regras e scripts pessoais presentes no ZIP não são necessários para compilar este projeto.

A licença MIT e os créditos originais estão preservados em [LICENSE](LICENSE). Os ícones da barra reutilizam os assets do Taurine; o ícone do aplicativo é um desenho vetorial nativo reproduzível com `./scripts/make-icon.sh`.
