<p align="center">
  <img src="Shitsurae/AssetSources/icon.png" alt="Shitsurae" width="192" />
</p>

# Shitsurae

[English](README.md)

**Shitsurae** は、作業ごとのウィンドウ配置をYAMLで定義し、キーボードやGUIから呼び出せるmacOS向けウィンドウマネージャーです。

独自の仮想ワークスペースを使うため、Mission Controlのデスクトップを増やさずに、コーディング、調査、コミュニケーションなどの作業空間を切り替えられます。

名前の由来は、空間を目的に合わせて整える日本の文化「室礼（しつらえ）」です。

<p align="center">
  <img src="https://github.com/yuki-yano/shitsurae/releases/download/app-v1.2.1/shitsurae-arrange.png" alt="複数ディスプレイと仮想ワークスペースを管理するShitsuraeのArrange画面" width="960" />
</p>

## できること

- アプリの起動、ウィンドウの配置、初期フォーカスを一度に適用する
- `Ctrl+1`から`Ctrl+9`で仮想ワークスペースを切り替える
- `Cmd+1`から`Cmd+9`で目的のウィンドウへ直接フォーカスする
- `Cmd+Tab`でウィンドウ単位のスイッチャーを開く
- 現在のウィンドウを別の仮想ワークスペースへ送る
- 左半分、右半分、最大化などのスナップ操作をショートカットに割り当てる
- ディスプレイごとに独立したレイアウトと仮想ワークスペースを管理する
- GUIとCLIのどちらからでも同じレイアウトを操作する

## 動作環境

- macOS 15 Sequoia以降
- アクセシビリティ権限（必須）
- 画面収録権限（スイッチャーにサムネイルを表示する場合のみ）

通常の利用で外部ネットワーク通信は必要ありません。

## インストール

Homebrew Caskでインストールします。

```bash
brew tap yuki-yano/shitsurae
brew install --cask shitsurae
xattr -dr com.apple.quarantine /Applications/Shitsurae.app
open /Applications/Shitsurae.app
```

`Shitsurae.app`は`/Applications`へ配置され、CLIの`shitsurae`も通常の`PATH`から実行できるようになります。

> [!WARNING]
> 配布版はnotarizeされていません。
> `xattr`はmacOSのquarantine属性を外すため、配布元を信頼できる場合だけ実行してください。

初回起動後、Shitsuraeの**Permissions**画面からシステム設定を開き、アクセシビリティ権限を有効にします。

サムネイル付きのウィンドウスイッチャーを使う場合は、画面収録権限も有効にしてください。
画面収録権限がなくても、スイッチャーはアプリアイコンを使って動作します。

## 最初のレイアウト

### 1. 設定ファイルを作る

`~/.config/shitsurae/work.yaml`を作成します。

```yaml
# yaml-language-server: $schema=https://raw.githubusercontent.com/yuki-yano/shitsurae/refs/heads/main/schemas/shitsurae-config.schema.json

layouts:
  work:
    initialFocus:
      slot: 1
    spaces:
      - spaceID: 1
        windows:
          - slot: 1
            launch: true
            match:
              bundleID: com.apple.TextEdit
            frame:
              x: "0%"
              y: "0%"
              width: "50%"
              height: "100%"
          - slot: 2
            launch: true
            match:
              bundleID: com.apple.Terminal
            frame:
              x: "50%"
              y: "0%"
              width: "50%"
              height: "100%"
      - spaceID: 2
        windows:
          - slot: 1
            launch: true
            match:
              bundleID: com.apple.Notes
            frame:
              x: "0%"
              y: "0%"
              width: "100%"
              height: "100%"
```

この設定は、Space 1にテキストエディットとターミナルを左右に並べ、Space 2にメモを最大表示します。

### 2. 設定を検証する

```bash
shitsurae validate --json
```

エラーがなければ、ウィンドウを動かさないdry runで実行内容を確認できます。

```bash
shitsurae arrange work --dry-run --json
```

### 3. レイアウトを適用する

```bash
shitsurae arrange work
```

GUIを使う場合は**Arrange**を開き、レイアウトに`work`を選んで**Apply**を押します。

Shitsuraeは対象アプリを起動し、ウィンドウを配置して、Space 1を表示します。
以後は`Ctrl+1`と`Ctrl+2`で二つの仮想ワークスペースを切り替えられます。

Shitsuraeを終了すると、退避中のウィンドウは画面内へ戻り、実行時のワークスペース状態は破棄されます。
次回起動時はレイアウトをもう一度適用してください。

## 日常の操作

デフォルトのショートカットは次のとおりです。

| 操作 | ショートカット |
| --- | --- |
| スロット1から9へフォーカス | `Cmd+1`から`Cmd+9` |
| Space 1から9へ切り替え | `Ctrl+1`から`Ctrl+9` |
| 現在のウィンドウをSpace 1から9へ送る | `Option+1`から`Option+9` |
| 次のウィンドウ | `Cmd+Ctrl+J` |
| 前のウィンドウ | `Cmd+Ctrl+K` |
| ウィンドウスイッチャー | `Cmd+Tab` |

`Cmd+Tab`は、最後に使った順でウィンドウを表示します。
別の仮想ワークスペースにあるウィンドウを選ぶと、そのワークスペースへ切り替えてからフォーカスします。

`mode.followFocus`はデフォルトで有効です。
Dockやマウスから管理対象ウィンドウへフォーカスした場合も、そのウィンドウが属する仮想ワークスペースへ自動的に切り替わります。

## GUI

メインウィンドウには、用途ごとの画面があります。

- **Arrange**：ディスプレイごとにレイアウトやSpaceを選び、配置を適用する
- **Workspace State**：現在追跡しているウィンドウと配置状態を確認する
- **Layouts**：YAMLから読み込んだ各Spaceのプレビューを確認する
- **General**：起動時の動作などを確認する
- **Shortcuts**：現在有効なショートカットを確認する
- **Permissions**：アクセシビリティ権限と画面収録権限を確認する
- **Diagnostics**：設定エラー、ディスプレイ、実行状態を確認する

メニューバーからもレイアウトの適用、設定ディレクトリの表示、アプリの終了ができます。

## 設定

### 設定ディレクトリ

Shitsuraeは次の順で設定ディレクトリを探します。

1. `$XDG_CONFIG_HOME/shitsurae/`
2. `~/.config/shitsurae/`

直下の`*.yml`と`*.yaml`をファイル名順に読み込むため、レイアウトやショートカットを複数ファイルへ分割できます。

設定ファイルは自動的に再読み込みされます。
読み込みに失敗した場合は直前の有効な設定を維持し、エラーを**Diagnostics**に表示します。

ログイン時にShitsuraeを起動する場合は、次の設定を追加します。

```yaml
app:
  launchAtLogin: true
```

### 保存されるデータ

Shitsuraeがローカルに保存する主なデータは次のとおりです。

| データ | 保存先 |
| --- | --- |
| 設定 | `$XDG_CONFIG_HOME/shitsurae/`または`~/.config/shitsurae/` |
| 実行時のワークスペース状態 | `$XDG_STATE_HOME/shitsurae/runtime-state.json`または`~/.local/state/shitsurae/runtime-state.json` |
| ログ | `~/Library/Logs/Shitsurae/shitsurae.log` |

実行時の状態ファイルは、退避中のウィンドウを安全に画面へ戻すために使われます。
Shitsuraeが管理しているウィンドウを手動で戻す前に、状態ファイルを削除しないでください。

### ウィンドウの特定

各ウィンドウは`match`で特定します。

- **`bundleID`**：アプリのbundle identifier（必須）
- **`title`**：ウィンドウタイトルを`equals`、`contains`、`regex`で指定
- **`profile`**：Chromium系ブラウザのプロファイルディレクトリ名
- **`role` / `subrole`**：アクセシビリティロール
- **`index`**：同じアプリ内でのウィンドウ番号
- **`excludeTitleRegex`**：一致したタイトルを除外

前面ウィンドウの情報は次のコマンドで確認できます。

```bash
shitsurae window current --json
```

同じ`bundleID`を複数のスロットで使う場合は、`title`、`profile`、`index`のいずれかで区別してください。
区別できない定義は設定エラーになります。

Chromium系ブラウザは`profile`を指定すると、プロファイル単位で起動と追跡ができます。

```yaml
- slot: 1
  launch: true
  match:
    bundleID: com.google.Chrome
    profile: Default
  frame:
    x: "0%"
    y: "0%"
    width: "100%"
    height: "100%"
```

### 位置とサイズ

`frame`では次の単位を使えます。

- `%`：ディスプレイに対する割合
- `pt`：macOSの論理座標
- `px`：物理ピクセル
- `r`：`0.0`から`1.0`の比率

`frame`を省略したウィンドウは、現在の位置とサイズを保ったまま仮想ワークスペースへ登録されます。

### ショートカット

すべてのグローバルショートカットはYAMLで変更できます。

```yaml
shortcuts:
  nextWindow:
    key: j
    modifiers: [cmd, ctrl]

  prevWindow:
    key: k
    modifiers: [cmd, ctrl]

  switcher:
    trigger:
      key: tab
      modifiers: [cmd]
    quickKeys: "1234567890qwertyuiopasdfghjkl"
    acceptKeys: [enter]
    cancelKeys: [esc]

  globalActions:
    - key: H
      modifiers: [cmd, ctrl]
      action:
        type: snap
        preset: leftHalf
    - key: L
      modifiers: [cmd, ctrl]
      action:
        type: snap
        preset: rightHalf
```

利用できるスナッププリセットは、`leftHalf`、`rightHalf`、`topHalf`、`bottomHalf`、`leftThird`、`centerThird`、`rightThird`、`maximize`、`center`です。

アプリ固有のショートカットと競合する場合は、そのアプリで特定のShitsuraeショートカットを無効化できます。
設定項目の一覧は[YAML Schema](schemas/shitsurae-config.schema.json)を参照してください。

### マルチディスプレイ

`monitors`で物理ディスプレイに安定した名前を付け、各レイアウトの`display.monitor`から参照します。

```yaml
monitors:
  main:
    primary: true
  side:
    width: 2560
    height: 1440

layouts:
  work:
    display:
      monitor: main
    spaces:
      - spaceID: 1
        windows: []

  reference:
    display:
      monitor: side
    spaces:
      - spaceID: 1
        windows: []
```

別々のディスプレイに割り当てたレイアウトは、一度に適用できます。

```bash
shitsurae arrange work reference
```

外部ディスプレイを切断すると、そのディスプレイのワークスペースは休止します。
再接続すると、Shitsuraeは宣言したディスプレイを解決し直してウィンドウを再配置します。

> [!IMPORTANT]
> 非プライマリディスプレイのレイアウトには、専用の`bundleID`、`title`、`profile`などを使った狭いマッチ条件を指定してください。
> ブラウザ本体の`bundleID`だけのような広い条件は、別のディスプレイにある同じアプリのウィンドウまで対象にする可能性があります。

## 仮想ワークスペースの仕組み

ShitsuraeはmacOSのネイティブSpaceを操作しません。

ワークスペースを切り替えると、表示対象のウィンドウを画面内へ戻し、それ以外の管理対象ウィンドウをディスプレイの外へ移動します。
画面外への移動を受け付けないアプリでは、そのウィンドウだけを最小化し、戻るときに復元します。

ダイアログやシートなどの一時的なウィンドウは画面内に保ち、操作が終わると親ウィンドウを本来のワークスペースへ戻します。

## CLI

よく使うコマンドを示します。

```bash
shitsurae layouts list
shitsurae validate --json
shitsurae diagnostics --json

shitsurae arrange work --dry-run --json
shitsurae arrange work

shitsurae space list --json
shitsurae space current --json
shitsurae space switch 2 --json

shitsurae window current --json
shitsurae window workspace 2 --json
shitsurae window set -x 0% -y 0% -w 50% -h 100%

shitsurae focus --slot 1
shitsurae switcher list --json
```

CLIはUnixドメインソケットでShitsuraeアプリへ接続します。
アプリが起動していない場合は自動的に起動します。

各サブコマンドのオプションは`shitsurae <subcommand> --help`で確認できます。

## トラブルシューティング

### レイアウトが読み込まれない

設定を検証し、**Diagnostics**に表示されるファイル名とエラー内容を確認します。

```bash
shitsurae validate --json
```

### ウィンドウが見つからない

**Permissions**でアクセシビリティ権限を確認し、対象ウィンドウを前面に出してマッチ情報を取得します。

```bash
shitsurae window current --json
```

同じアプリのウィンドウを複数登録する場合は、`title`、`profile`、`index`で区別してください。

### ショートカットが反応しない

**Shortcuts**で現在の割り当てを確認します。
macOSや前面アプリが同じキーを使っている場合は、Shitsurae側のキーを変更するか、`shortcuts.disabledInApps`で競合するアプリだけ無効化します。

### Recovery requiredと表示される

これは、ウィンドウの表示状態を安全に確定できなかった操作が残っていることを示します。
まずShitsuraeを通常終了して、退避中のウィンドウが画面内へ戻るか確認してください。

状態を手動で解除するのは、すべての管理対象ウィンドウが画面内にあり、保留中の復元情報が不要だと確認できた場合だけにします。

```bash
shitsurae space recover --force-clear-pending --yes --json
```

解除後に表示状態を揃える場合は、対象のSpaceへ`--reconcile`付きで切り替えます。

```bash
shitsurae space switch 1 --reconcile --json
```

## アンインストール

アプリだけを削除する場合は、次のコマンドを使います。

```bash
brew uninstall --cask shitsurae
```

設定とログも削除する場合は、続けて`zap`を実行します。

```bash
brew zap shitsurae
```

## ソースからビルド

```bash
swift build
swift test
make app
```

アプリバンドルは`dist/Shitsurae.app`へ生成されます。

## ライセンス

MIT
