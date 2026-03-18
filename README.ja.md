<p align="center">
  <img src="Shitsurae/AssetSources/icon.png" alt="Shitsurae" width="256" />
</p>

# Shitsurae

[English](README.md)

**Shitsurae** は、1 コマンドでデスクトップを整える macOS 向けワークスペース整列ツールです。

名前の由来は *室礼（しつらえ）*——季節や行事に合わせて室内の調度品を整え、空間を美しく機能的に仕立てる日本の伝統文化です。物理的な部屋の室礼と同じように、デジタルの作業空間にも"しつらえ"の美学を持ち込むことがコンセプトです。

## 解決する課題

- 毎朝のウィンドウ再配置を手作業で繰り返している
- 外部ディスプレイの接続/切断でレイアウトが崩れる
- `Cmd+Tab` で多数のウィンドウから目的のものを探すのが遅い
- 作業内容ごとに同じレイアウト作業を何度も繰り返す（コーディング、レビュー、ミーティングなど）

理想の配置を YAML で定義し、1 コマンドで適用できます：

```bash
shitsurae arrange work
```

## 主な機能

### 1. レイアウト一括適用（`arrange`）

YAML にレイアウトを定義し、`shitsurae arrange <name>` を実行すると：

- 未起動のアプリを自動起動（`launch: true`）
- ウィンドウを指定した Space へ移動
- 指定座標・サイズに配置
- 配置完了後、初期フォーカスを設定
- `--state-only` で runtime state のみ更新

位置・サイズの単位は柔軟に指定可能：`%`（画面比率）、`pt`（論理座標）、`px`（物理ピクセル）、`r`（0.0〜1.0 の比率）。

### 2. キーボードファーストな操作

すべての操作をキーボードで完結できます。デフォルトショートカット：

| 操作 | デフォルト | 説明 |
|------|-----------|------|
| スロットフォーカス | `Cmd+1` 〜 `Cmd+9` | 番号を割り当てたウィンドウに直接フォーカス |
| workspace 切り替え | `Ctrl+1` 〜 `Ctrl+9` | Virtual mode の active workspace を切り替え |
| window を workspace へ移動 | `Alt+1` 〜 `Alt+9` | Virtual mode で現在の window を指定した仮想 workspace へ送る |
| 次のウィンドウ | `Cmd+Ctrl+J` | 現在 Space 内で次のウィンドウに巡回 |
| 前のウィンドウ | `Cmd+Ctrl+K` | 現在 Space 内で前のウィンドウに巡回 |
| スイッチャー | `Cmd+Tab` | ウィンドウスイッチャーを表示 |
| スナップ | 任意設定 | 左半分・右半分・最大化など、プリセット配置 |

すべてのショートカットは YAML で自由にカスタマイズ可能。特定アプリが前面にあるときだけ無効化する設定もできます（例：Discord の `Cmd+1` と競合しないように制御）。

### 3. 内蔵ウィンドウスイッチャー

`Cmd+Tab`（カスタマイズ可能）で起動する独自のスイッチャー：

- ウィンドウは MRU（最後に使った順）で並び、直前にアクティブだったウィンドウが 2 番目に表示されるため、1 回の `Cmd+Tab` で直前のウィンドウに切り替わる（Windows の Alt+Tab と同じ動作）
- Virtual mode では OS レベルの `NSWorkspace.didActivateApplicationNotification` でアクティベーションを追跡するため、Dock クリック・Mission Control・直接クリックなどすべての操作で MRU 順序が更新される
- 各候補に `1`, `2`, `3`, `4`, … のクイックキーが割り当てられ、1 打鍵で即時切替
- 修飾キーを離すと常に選択確定
- トリガー、accept/cancel キー、クイックキー文字列を個別設定可能

一方で `Cmd+Ctrl+J/K` は別順序で動作し、`slot` 付きウィンドウを先頭固定、その後ろに `slot` なしウィンドウをその Space で観測した順に並べます。`shortcuts.cycle.mode: overlay` を指定すると、この順序を使った overlay UI で確定操作できます。

### 4. ウィンドウスナップ

プリセットによるウィンドウ配置操作：

- `leftHalf`・`rightHalf`・`topHalf`・`bottomHalf`
- `leftThird`・`centerThird`・`rightThird`
- `maximize`・`center`

任意のグローバルショートカットに割り当てられます。

### 5. Virtual mode

`mode.space: virtual` を有効にすると、`spaceID` は macOS の native Space 番号ではなく論理 workspace ID として扱われます。すべての workspace 管理は単一の native Space 上で、ウィンドウの画面内/画面外移動によって行われます。

```yaml
mode:
  space: virtual
  followFocus: true  # デフォルト: true
```

#### 初期化

1. `shitsurae arrange <layout> --dry-run --json` で `availableSpaceIDs` を確認する
2. `shitsurae arrange <layout> --state-only --space <id>` で active layout / active space を初期化する
3. 対象 workspace の tracked window を host native Space 上に揃えてから `shitsurae arrange <layout> --space <id>` を実行する

GUI でも同じ導線です：*Initialize Active Space*（step 2）と *Apply Selected Space*（step 3）。

#### 動作

- `space current/list/switch` は active virtual space を正本として扱う
- `focus --slot`、cycle、switcher は active virtual space の tracked window だけを対象にする
- `switcher list --json --include-all-spaces true` は active layout に属する全 tracked window を列挙する
- `Ctrl+1`〜`Ctrl+9` は active virtual workspace の切り替えショートカット
- `Alt+1`〜`Alt+9` / `window workspace <id>` は tracked window を別 workspace に再割り当てし、active space 外へ送った window は minimize せず画面外へ退避させる

#### Follow-focus

`mode.followFocus` が有効な場合（デフォルト有効）、Dock クリック・Mission Control・直接クリック・`Cmd+Tab` など、あらゆる手段で管理対象のウィンドウにフォーカスが当たると、そのウィンドウが所属する virtual workspace へ自動的に切り替わります。

### 6. メニューバー + GUI アプリ

Shitsurae は通常の macOS アプリとして起動し、メニューバーにも常駐します。

#### メニューバー

システムメニューバーからいつでもアクセス可能：

- **レイアウトサブメニュー** — 定義済みレイアウトごとにサブメニューが表示され：
  - *Apply All* — すべての Space にレイアウトを適用
  - *Apply Current Space* — 現在アクティブな Space にのみ適用
- **Open Shitsurae** — メインウィンドウを開く
- **Preferences…** — 設定ウィンドウを開く
- **Open Config Directory** — 設定フォルダを Finder で開く
- **Quit** — アプリを終了

#### メインウィンドウ

サイドバー付きの GUI で、**Arrange**・**Layouts**・**General**・**Shortcuts**・**Permissions**・**Diagnostics** のセクションで構成されています。

<p align="center">
  <img src="https://github.com/user-attachments/assets/3adc77fe-03f4-4035-99d6-46ec116cf171" alt="レイアウト詳細ビュー" width="720" />
</p>
<p align="center">
  <img src="https://github.com/user-attachments/assets/8852c847-3091-4773-9c6c-5e8c4d1b6bfd" alt="レイアウト詳細ビュー (dashboard)" width="720" />
</p>
<p align="center">
  <img src="https://github.com/user-attachments/assets/89261418-4110-491f-8bc0-4920fe5de1af" alt="ショートカットビュー" width="720" />
</p>

#### ウィンドウスイッチャーオーバーレイ

<p align="center">
  <img src="https://github.com/user-attachments/assets/9bc0e59f-392a-4c0a-8ea1-2facc9d7b104" alt="ウィンドウスイッチャーオーバーレイ" width="720" />
</p>

スイッチャーホットキー（デフォルトは `Cmd+Tab`）で表示されるフローティングオーバーレイ：

- 候補ウィンドウが横並びのカードで表示され、各カードには：
  - アプリアイコンとウィンドウタイトル
  - クイック選択キー（`1`、`2`、`3`、…）
  - bundle ID
  - ウィンドウのサムネイルプレビュー（Screen Recording 権限が必要）またはアイコンのフォールバック
- 選択中のカードはハイライト表示
- **キーボード：** Tab / Shift+Tab で巡回、数字キーでクイック選択、カスタム accept/cancel キー、修飾キーを離して確定
- **マウス：** カードをクリックして切替

### 7. CLI と自動化

シェルスクリプトや自動化から同じ機能を利用できます。

```bash
shitsurae arrange <layout> --dry-run --json    # 実行計画の確認（変更なし）
shitsurae arrange <layout> --json              # レイアウト適用
shitsurae arrange <layout> --space 2 --json    # 特定 Space に適用
shitsurae arrange <layout> --state-only --json # runtime state のみ更新
shitsurae layouts list                         # 定義済みレイアウト一覧
shitsurae validate --json                      # 設定ファイルの検証
shitsurae diagnostics --json                   # 診断情報
shitsurae space current --json                 # 現在の Space 情報
shitsurae space list --json                    # Space 一覧
shitsurae space switch 2 --json                # virtual mode の active space 切替
shitsurae space recover --force-clear-pending --yes --json # recovery state の強制解除
shitsurae window current --json                # 現在フォーカスウィンドウの情報
shitsurae window workspace 2 --json            # virtual mode で window を workspace 2 へ再割り当て
shitsurae window set --x 0% --y 0% --w 50% --h 100%   # 移動 + リサイズ
shitsurae focus --slot 1                       # スロット指定フォーカス
shitsurae focus --bundle-id com.apple.TextEdit # アプリ指定フォーカス
shitsurae switcher list --json                 # スイッチャー候補一覧
shitsurae switcher list --json --include-all-spaces true  # virtual mode では active layout 全体を列挙
```

`window workspace` / `window move` / `window resize` / `window set` はセレクター未指定時、現在フォーカス中のウィンドウを対象にします。セレクター：`--window-id`（ウィンドウ指定）、`--bundle-id`（アプリ指定）、`--title`（`--bundle-id` と組み合わせ）。

### 8. マルチディスプレイ対応

- `primary` / `secondary` のロール指定、解像度条件でディスプレイをマッチ
- 同じ Space ID に複数の解像度別定義を書いておくと、一致した最初の定義が自動適用（first-match）
- MacBook 単体と外部モニター接続時で、設定を書き換えずに適切なレイアウトが選ばれる

### 9. 設定自動リロード

- 設定ディレクトリ内の `*.yml` / `*.yaml` をファイル名順で読み込み
- ファイル変更を監視し自動リロード
- 構文エラー時は直前の有効な設定を維持し、診断画面にエラー内容を表示

## 動作要件

- macOS 15（Sequoia）以降
- Accessibility 権限（必須）
- Screen Recording 権限（任意——スイッチャーのサムネイル表示を使う場合のみ）

通常運用で外部ネットワーク通信は不要です。

## インストール

### Homebrew Cask でインストール

```bash
brew tap yuki-yano/shitsurae
brew install --cask shitsurae
xattr -dr com.apple.quarantine /Applications/Shitsurae.app
open /Applications/Shitsurae.app
```

この構成では次が入ります：

- `Shitsurae.app` が `/Applications` に配置される
- `shitsurae` CLI が Homebrew の `bin` 配下に symlink され、通常の `PATH` から呼べる

> [!WARNING]
> Homebrew で入れた配布版は、初回起動前に `xattr -dr com.apple.quarantine /Applications/Shitsurae.app` の実行が必須です。
> これは未署名アプリに対する macOS Gatekeeper の quarantine を外す操作なので、`https://github.com/yuki-yano/shitsurae` を信頼できる場合だけ実行してください。

削除するときは次を使います：

```bash
brew uninstall --cask shitsurae
brew zap shitsurae    # 任意: 設定とログも削除
```

### `.app` を直接配布した場合の初回起動（Notarize なし）

`.app` をそのまま配布した場合、初回は quarantine を外して起動してください。

```bash
xattr -dr com.apple.quarantine Shitsurae.app
open Shitsurae.app
```

## 設定

### 設定ディレクトリ

次の順で解決します：

1. `$XDG_CONFIG_HOME/shitsurae/`
2. `~/.config/shitsurae/`

すべての `*.yml` / `*.yaml` がファイル名順で読み込まれます。用途別にファイルを分割できます（`work.yml`、`home.yml` など）。

### YAML Schema / LSP

YAML LSP の補完と validation を有効にするには、設定ファイルの先頭で schema を参照します：

```yaml
# yaml-language-server: $schema=https://raw.githubusercontent.com/yuki-yano/shitsurae/refs/heads/main/schemas/shitsurae-config.schema.json
```

### 基本例

```yaml
layouts:
  work:
    initialFocus:
      slot: 1
    spaces:
      - spaceID: 1
        windows:
          - slot: 1
            launch: false
            match:
              bundleID: com.apple.TextEdit
            frame:
              x: "0%"
              y: "0%"
              width: "50%"
              height: "100%"
          - slot: 2
            launch: false
            match:
              bundleID: com.apple.Terminal
            frame:
              x: "50%"
              y: "0%"
              width: "50%"
              height: "100%"
```

その他のサンプルは `samples/` にあります。

### ウィンドウマッチング

`match` でウィンドウを特定します：

- `bundleID`（必須）——アプリの bundle identifier
- `title` —— `equals`・`contains`・`regex` で指定
- `profile` —— Chromium 系ブラウザの profile ディレクトリ名
- `role` / `subrole` —— accessibility ロール
- `index` —— アプリ内のウィンドウインデックス（1 始まり）
- `excludeTitleRegex` —— タイトルが一致するウィンドウを除外

### Chromium 系ブラウザの profile 指定

Chrome・Brave・Edge・Chromium では、`match.profile` で profile ごとのウィンドウを指定できます：

```yaml
- slot: 1
  launch: true
  match:
    bundleID: com.google.Chrome
    profile: Default
  frame:
    x: "0%"
    y: "0%"
    width: "50%"
    height: "100%"
```

- `profile` は Chromium の profile ディレクトリ名です（`Default`、`Profile 1` など）。表示名ではありません。
- `launch: true` の場合、`--profile-directory=<profile> --new-window` 付きで起動します。
- `shitsurae window current --json` の `profile` に、判定できた profile 名が出ます。

### Mode

```yaml
mode:
  space: virtual    # native（デフォルト）| virtual
  followFocus: true # デフォルト: true — ウィンドウフォーカス時に workspace を自動切替（virtual mode のみ）
```

### Space 移動方式

```yaml
executionPolicy:
  spaceMoveMethod: drag
  spaceMoveMethodInApps:
    org.alacritty: displayRelay
```

- `drag` —— ウィンドウをドラッグしたまま macOS の desktop shortcut を送る
- `displayRelay` —— マルチディスプレイの `perDisplay` 環境で、いったん別ディスプレイに退避して target space を切り替えてから戻す

### 無視ルール

arrangement や focus 操作から特定のアプリ・ウィンドウを除外します：

```yaml
ignore:
  apply:
    apps:
      - com.apple.finder
    windows:
      - bundleID: com.google.Chrome
        titleRegex: "^DevTools"
  focus:
    apps:
      - com.apple.SystemPreferences
```

### アプリ挙動

```yaml
app:
  launchAtLogin: true
```

### ショートカットのカスタマイズ

```yaml
shortcuts:
  # 前面アプリ単位で Cmd+1..9 だけの有効/無効を切り替え
  focusBySlotEnabledInApps:
    com.hnc.Discord: false
    com.tinyspeck.slackmacgap: false
    org.alacritty: false

  # Virtual mode: current window を workspace へ送る（デフォルト Alt+1..9）
  moveCurrentWindowToSpace:
    - slot: 1
      key: 1
      modifiers: [alt]
    - slot: 2
      key: 2
      modifiers: [alt]

  # Virtual mode: active workspace を切り替え（デフォルト Ctrl+1..9）
  switchVirtualSpace:
    - slot: 1
      key: 1
      modifiers: [ctrl]
    - slot: 2
      key: 2
      modifiers: [ctrl]

  # Cmd+Ctrl+J / K の候補から除外
  cycleExcludedApps:
    - com.hnc.Discord

  # Cmd+Tab の候補から除外
  switcherExcludedApps:
    - com.tinyspeck.slackmacgap

  nextWindow:
    key: j
    modifiers: [cmd, ctrl]

  prevWindow:
    key: k
    modifiers: [cmd, ctrl]

  cycle:
    mode: overlay # direct | overlay
    quickKeys: "123456789"
    acceptKeys: [enter]
    cancelKeys: [esc]

  switcher:
    trigger:
      key: tab
      modifiers: [cmd]
    quickKeys: "1234567890qwertyuiopasdfghjklzxcvbnm"
    acceptKeys: [enter]
    cancelKeys: [esc]

  # スナッププリセットのショートカット
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

## ソースからビルド

```bash
swift build
```

テスト実行：

```bash
swift test
```

アプリバンドル生成：

```bash
make app
```

出力先：

- `dist/Shitsurae.app`
- 同梱 CLI：`dist/Shitsurae.app/Contents/Resources/shitsurae`

## ライセンス

MIT
