<img src="assets/readme/icon.png" alt="Ícone" width="200"/>

# Taurine
### Não deixe seu Mac dormir. Nem de tampa fechada.

Taurine é um pequeno app de barra de menus que mantém o Mac acordado, útil para tarefas longas que não podem ser interrompidas pelo repouso. Diferente do [Caffeine](https://github.com/domzilla/Caffeine), do qual deriva, também impede o repouso quando a tampa do MacBook é fechada, e um componente auxiliar garante que o repouso volte ao normal se o app fechar, travar ou o Mac reiniciar.

Requer macOS 14.6 ou posterior.

### Instalação

Baixe o `.dmg` mais recente em [Releases](https://github.com/nandoolle/taurine/releases), arraste o Taurine para a pasta Aplicativos e abra.

O app não é notarizado. Na primeira abertura, clique com o botão direito → **Abrir**, ou libere em *Ajustes do Sistema → Privacidade e Segurança → Abrir Mesmo Assim*.

Depois, em **Preferências**, clique em **Instalar componente auxiliar…**. É a única vez em que a senha de administrador é pedida. Sem o componente, o Taurine não ativa.

### Uso

O Taurine coloca uma latinha na barra de menus. Clique nela para ligar ou desligar: latinha aberta significa que o Mac não vai dormir, escurecer a tela nem iniciar o descanso de tela, mesmo com a tampa fechada.

<img src="assets/readme/menubar.png" alt="Barra de menus" width="460"/>

Para mais controle, clique com o botão direito (ou ⌘-clique) no ícone. Dali você abre as Preferências ou define por quanto tempo o Taurine deve ficar ativo.

<img src="assets/readme/menu.png" alt="Menu" width="460"/>

Nas Preferências você define a duração padrão, se o Taurine ativa ao abrir, um som discreto ao ativar, e a **proteção da bateria**: na bateria, o Taurine desliga sozinho quando a carga chega ao limite escolhido (60% por padrão). Na tomada o corte não se aplica.

<img src="assets/readme/preferences.png" alt="Preferências" width="645"/>

Um triângulo no ícone indica que o repouso precisa ser restaurado. Use **Restaurar repouso…**.

### Como funciona

Manter o Mac acordado de tampa fechada exige `pmset -a disablesleep 1`, uma configuração global e persistente que precisa de root. O Taurine instala um LaunchDaemon (`dev.taurine.helper`) que é o único a executar esse comando, e conversa com ele por XPC.

Quando a conexão com o app cai (fechamento, falha, encerramento forçado, logout), o componente restaura o repouso. Em todo boot restaura o repouso incondicionalmente e, se o app tiver sido apagado, remove-se sozinho. Arquivos instalados:

- `/Library/PrivilegedHelperTools/dev.taurine.helper`
- `/Library/LaunchDaemons/dev.taurine.helper.plist`
- `/var/db/taurine/`

Para remover: Preferências → **Remover componente auxiliar…**. Manualmente, restaurando o repouso antes de tudo:

```sh
sudo pmset -a disablesleep 0
sudo launchctl bootout system/dev.taurine.helper
sudo rm -f /Library/PrivilegedHelperTools/dev.taurine.helper /Library/LaunchDaemons/dev.taurine.helper.plist
sudo rm -rf /var/db/taurine
```

### FAQ

##### Por que pedir senha de administrador?

Porque `disablesleep` só pode ser alterado por root. O Caffeine e similares usam apenas asserções do IOKit, que não exigem senha, mas também não mantêm o Mac acordado de tampa fechada.

##### E se o Mac desligar por falta de bateria com o Taurine ativo?

O componente auxiliar roda em todo boot e restaura o repouso antes de qualquer coisa. Fechar a tampa volta a colocar o Mac para dormir.

##### Posso fechar o app e manter o Mac acordado?

Não. Taurine fechado significa Mac dormindo normalmente. Essa é a regra que o componente auxiliar existe para garantir.

### Compilar

Sem dependências externas. Com Swift 6.2 e o SDK do macOS:

```sh
./scripts/build.sh      # gera build/Taurine.app (assinatura ad hoc)
./scripts/make-dmg.sh   # gera build/Taurine-<versão>.dmg
swift test
```

Também é possível abrir `src/Taurine.xcodeproj` ou usar `./scripts/build-xcode.sh`.

### Créditos e licença

Baseado no Caffeine de Tomas Franzén, Michael Jones e Dominic Rodemer. Licença MIT, com os créditos originais preservados em [LICENSE](LICENSE). Histórico de versões em [CHANGELOG.md](CHANGELOG.md).
