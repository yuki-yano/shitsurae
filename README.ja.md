<p align="center">
  <img src="Shitsurae/AssetSources/icon.png" alt="Shitsurae" width="256" />
</p>

# Shitsurae

[English](README.md)

**Shitsurae** は、独自の仮想デスクトップ(virtual workspace)でウィンドウを管理する macOS 向けウィンドウマネージャーです。

名前の由来は *室礼(しつらえ)*——季節や行事に合わせて室内の調度品を整え、空間を美しく機能的に仕立てる日本の伝統文化です。物理的な部屋の室礼と同じように、デジタルの作業空間にも"しつらえ"の美学を持ち込むことがコンセプトです。

> [!NOTE]
> v2 で Mission Control / macOS ネイティブ Space 連携を廃止し、独自仮想デスクトップ専用に書き直しました。移行手順は [v1 からの移行](#v1-からの移行) を参照してください。

## 解決する課題

- 毎朝のウィンドウ再配置を手作業で繰り返している
- 外部ディスプレイの接続/切断でレイアウトが崩れる
- `Cmd+Tab` で多数のウィンドウから目的のものを探すのが遅い
- 作業内容ごとに同じレイアウト作業を何度も繰り返す(コーディング、レビュー、ミーティングなど)
- Mission Control のデスクトップ切り替えアニメーションが遅い

理想の配置を YAML で定義し、1 コマンドで適用できます:

```bash
shitsurae arrange work
```

## 仕組み

Shitsurae は macOS のネイティブ Space(Mission Control)を一切使いません。すべての仮想 workspace は単一のデスクトップ上で、ウィンドウの**画面内/画面外の座標移動**によって実現されます。

- workspace 切り替え = 対象ウィンドウを画面内へ、それ以外を画面外(1px 外側)へ移動
- アニメーションなしの即時切り替え
- Mission Control・ネイティブデスクトップの設定に依存しない
- ダイアログ・シートなどの一時 UI は切り替え中も画面内に維持し、親ウィンドウを一時保護して、ダイアログ終了後に本来の workspace へ戻す

## 主な機能

### 1. レイアウト一括適用(`arrange`)

YAML にレイアウトを定義し、`shitsurae arrange <name>` を実行すると:

- 未起動のアプリを自動起動(`launch: true`)
- ウィンドウを指定座標・サイズに配置
- 仮想 workspace への割り当てを記録し、アクティブでない workspace のウィンドウを退避
- 配置完了後、初期フォーカスを設定
- `--state-only` で runtime state のみ更新

位置・サイズの単位は柔軟に指定可能: `%`(画面比率)、`pt`(論理座標)、`px`(物理ピクセル)、`r`(0.0〜1.0 の比率)。

### 2. キーボードファーストな操作

すべての操作をキーボードで完結できます。デフォルトショートカット:

| 操作 | デフォルト | 説明 |
|------|-----------|------|
| スロットフォーカス | `Cmd+1` 〜 `Cmd+9` | 番号を割り当てたウィンドウに直接フォーカス |
| workspace 切り替え | `Ctrl+1` 〜 `Ctrl+9` | アクティブな仮想 workspace を切り替え |
| window を workspace へ移動 | `Alt+1` 〜 `Alt+9` | 現在の window を指定した仮想 workspace へ送る |
| 次のウィンドウ | `Cmd+Ctrl+J` | アクティブ workspace 内で次のウィンドウに巡回 |
| 前のウィンドウ | `Cmd+Ctrl+K` | アクティブ workspace 内で前のウィンドウに巡回 |
| スイッチャー | `Cmd+Tab` | ウィンドウスイッチャーを表示 |
| スナップ | 任意設定 | 左半分・右半分・最大化など、プリセット配置 |

すべてのショートカットは YAML で自由にカスタマイズ可能。特定アプリが前面にあるときだけ無効化する設定もできます(例: Discord の `Cmd+1` と競合しないように制御)。

### 3. 内蔵ウィンドウスイッチャー

`Cmd+Tab`(カスタマイズ可能)で起動する独自のスイッチャー:

- ウィンドウは MRU(最後に使った順)で並び、直前にアクティブだったウィンドウが 2 番目に表示されるため、1 回の `Cmd+Tab` で直前のウィンドウに切り替わる(Windows の Alt+Tab と同じ動作)
- OS レベルの `NSWorkspace.didActivateApplicationNotification` でアクティベーションを追跡するため、Dock クリック・直接クリックなどすべての操作で MRU 順序が更新される
- 各候補に `1`, `2`, `3`, … のクイックキーが割り当てられ、1 打鍵で即時切替
- 修飾キーを離すと常に選択確定
- 別 workspace のウィンドウを選ぶと、その workspace へ自動的に切り替わる
- トリガー、accept/cancel キー、クイックキー文字列を個別設定可能

一方で `Cmd+Ctrl+J/K` は別順序で動作し、`slot` 付きウィンドウを先頭固定、その後ろに `slot` なしウィンドウを並べます。`shortcuts.cycle.mode: overlay` を指定すると、この順序を使った overlay UI で確定操作できます。

### 4. ウィンドウスナップ

プリセットによるウィンドウ配置操作:

- `leftHalf`・`rightHalf`・`topHalf`・`bottomHalf`
- `leftThird`・`centerThird`・`rightThird`
- `maximize`・`center`

任意のグローバルショートカットに割り当てられます。

### 5. Follow-focus

`mode.followFocus` が有効な場合(デフォルト有効)、Dock クリック・直接クリック・`Cmd+Tab` など、あらゆる手段で管理対象のウィンドウにフォーカスが当たると、そのウィンドウが所属する仮想 workspace へ自動的に切り替わります。

### 6. メニューバー + GUI アプリ

Shitsurae は通常の macOS アプリとして起動し、メニューバーにも常駐します。

- **レイアウトサブメニュー** — *Apply All* / *Apply Current Space*
- **Open Shitsurae** — メインウィンドウ(Arrange / Layouts / General / Shortcuts / Permissions / Diagnostics)
- **Open Config Directory** — 設定フォルダを Finder で開く
- **Quit** — アプリを終了(終了時、退避中のウィンドウはすべて画面内に復元されます)

### 7. CLI と自動化

シェルスクリプトや自動化から同じ機能を利用できます。CLI はアプリ本体に接続して動作し、アプリが起動していなければ自動的に起動します。

```bash
shitsurae arrange <layout> --dry-run --json    # 実行計画の確認(変更なし)
shitsurae arrange <layout> --json              # レイアウト適用
shitsurae arrange <layout> --space 2 --json    # 特定 workspace に適用
shitsurae arrange <layout> --state-only --json # runtime state のみ更新
shitsurae layouts list                         # 定義済みレイアウト一覧
shitsurae validate --json                      # 設定ファイルの検証
shitsurae diagnostics --json                   # 診断情報
shitsurae space current --json                 # アクティブ workspace 情報
shitsurae space list --json                    # workspace 一覧
shitsurae space switch 2 --json                # アクティブ workspace 切替
shitsurae space recover --force-clear-pending --yes --json # recovery state の強制解除
shitsurae window current --json                # 現在フォーカスウィンドウの情報
shitsurae window workspace 2 --json            # window を workspace 2 へ再割り当て
shitsurae window set -x 0% -y 0% -w 50% -h 100%   # 移動 + リサイズ
shitsurae focus --slot 1                       # スロット指定フォーカス
shitsurae focus --bundle-id com.apple.TextEdit # アプリ指定フォーカス
shitsurae switcher list --json                 # スイッチャー候補一覧
shitsurae switcher list --json --include-all-spaces true  # 全 workspace の候補を列挙
```

`window workspace` / `window move` / `window resize` / `window set` はセレクター未指定時、現在フォーカス中のウィンドウを対象にします。セレクター: `--window-id`(ウィンドウ指定)、`--bundle-id`(アプリ指定)、`--title`(`--bundle-id` と組み合わせ)。

### 8. マルチディスプレイ対応

- `primary` / `secondary` のロール指定、解像度条件でディスプレイをマッチ
- ディスプレイの接続/切断を検知してウィンドウ配置を自動再調整
- ディスプレイの識別はディスプレイ UUID ベースで、再接続後も安定

### 9. 設定自動リロード

- 設定ディレクトリ内の `*.yml` / `*.yaml` をファイル名順で読み込み
- ファイル変更を監視し自動リロード
- 構文エラー時は直前の有効な設定を維持し、診断画面にエラー内容を表示

## 動作要件

- macOS 15(Sequoia)以降
- Accessibility 権限(必須)
- Screen Recording 権限(任意——スイッチャーのサムネイル表示を使う場合のみ)

通常運用で外部ネットワーク通信は不要です。

## アーキテクチャ

v2 は 2 プロセス構成です:

- **Shitsurae.app** — メニューバー常駐 GUI。仮想 workspace 状態の唯一のオーナーで、ホットキー・スイッチャー・follow-focus・設定リロードを担当
- **shitsurae CLI** — Unix ドメインソケット経由でアプリに接続する薄いクライアント

v1 の常駐エージェント(ShitsuraeAgent + XPC + launchctl)は廃止されました。

## インストール

### Homebrew Cask でインストール

```bash
brew tap yuki-yano/shitsurae
brew install --cask shitsurae
xattr -dr com.apple.quarantine /Applications/Shitsurae.app
open /Applications/Shitsurae.app
```

この構成では次が入ります:

- `Shitsurae.app` が `/Applications` に配置される
- `shitsurae` CLI が Homebrew の `bin` 配下に symlink され、通常の `PATH` から呼べる

> [!WARNING]
> Homebrew で入れた配布版は、初回起動前に `xattr -dr com.apple.quarantine /Applications/Shitsurae.app` の実行が必須です。
> これは未署名アプリに対する macOS Gatekeeper の quarantine を外す操作なので、`https://github.com/yuki-yano/shitsurae` を信頼できる場合だけ実行してください。

削除するときは次を使います:

```bash
brew uninstall --cask shitsurae
brew zap shitsurae    # 任意: 設定とログも削除
```

### `.app` を直接配布した場合の初回起動(Notarize なし)

```bash
xattr -dr com.apple.quarantine Shitsurae.app
open Shitsurae.app
```

## 設定

### 設定ディレクトリ

次の順で解決します:

1. `$XDG_CONFIG_HOME/shitsurae/`
2. `~/.config/shitsurae/`

すべての `*.yml` / `*.yaml` がファイル名順で読み込まれます。用途別にファイルを分割できます(`work.yml`、`home.yml` など)。

### YAML Schema / LSP

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
      - spaceID: 2
        windows:
          - slot: 1
            launch: false
            match:
              bundleID: com.apple.Notes
            frame:
              x: "0%"
              y: "0%"
              width: "100%"
              height: "100%"
```

`spaceID` は仮想 workspace の論理番号です。その他のサンプルは `samples/` にあります。

### 始め方

`shitsurae arrange <layout>` を 1 回実行するだけです。ウィンドウの起動・配置・追跡・非アクティブ workspace の退避までまとめて行われます。GUI では *Apply All* が同じ操作です。

- runtime state はアプリ終了時にすべての hidden window を復元できた場合に破棄されます。復元を確認できない場合は、次回の recovery のため保持されます
- `--dry-run --json` で実行計画と `availableSpaceIDs` を事前確認できます
- `--state-only` はウィンドウを動かさずに追跡状態だけ作る上級者向けオプションです(通常は不要)

### ウィンドウマッチング

`match` でウィンドウを特定します:

- `bundleID`(必須)——アプリの bundle identifier
- `title` —— `equals`・`contains`・`regex` で指定
- `profile` —— Chromium 系ブラウザの profile ディレクトリ名
- `role` / `subrole` —— accessibility ロール
- `index` —— アプリ内のウィンドウインデックス(1 始まり)
- `excludeTitleRegex` —— タイトルが一致するウィンドウを除外

> [!IMPORTANT]
> 同じ `bundleID` を複数のスロットで使う場合は、各スロットに `title` / `profile` / `index` のいずれかの区別子が必須です(設定ロード時に検証されます)。区別子なしの曖昧なマッチングは、ウィンドウの追跡破綻の原因になるため v2 ではエラーになります。

### Chromium 系ブラウザの profile 指定

Chrome・Brave・Edge・Chromium では、`match.profile` で profile ごとのウィンドウを指定できます:

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

- `profile` は Chromium の profile ディレクトリ名です(`Default`、`Profile 1` など)。表示名ではありません。
- `launch: true` の場合、`--profile-directory=<profile> --new-window` 付きで起動します。
- `shitsurae window current --json` の `profile` に、判定できた profile 名が出ます。

### Mode

```yaml
mode:
  followFocus: true # デフォルト: true — ウィンドウフォーカス時に workspace を自動切替
```

### 無視ルール

arrangement や focus 操作から特定のアプリ・ウィンドウを除外します:

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

  # current window を workspace へ送る(デフォルト Alt+1..9)
  moveCurrentWindowToSpace:
    - slot: 1
      key: "1"
      modifiers: [alt]

  # active workspace を切り替え(デフォルト Ctrl+1..9)
  switchVirtualSpace:
    - slot: 1
      key: "1"
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

## v1 からの移行

v2 は Mission Control / ネイティブ Space 連携を廃止しました。互換性のための変更点:

1. **設定ファイル**: 次の 2 キーを削除してください(残っているとロード時エラーになります)
   - `mode.space`(常に virtual 動作になりました。`mode.followFocus` はそのまま使えます)
   - `executionPolicy`(セクションごと削除)
2. **runtime state**: v1 の状態ファイルは初回起動時に自動的に破棄されます(バックアップが `runtime-state.discarded-*.json` として残ります)。`shitsurae arrange <layout> --state-only --space <id>` で再ブートストラップしてください。
3. **同一アプリの複数スロット**: 同じ `bundleID` を複数スロットに割り当てている場合、各スロットに `title` / `profile` / `index` の区別子が必要になりました。
4. **ShitsuraeAgent は廃止**: `~/Library/LaunchAgents/com.yuki-yano.shitsurae.agent.plist` が残っていれば削除して構いません。

## ソースからビルド

```bash
swift build
```

テスト実行:

```bash
swift test
```

アプリバンドル生成:

```bash
make app
```

出力先:

- `dist/Shitsurae.app`
- 同梱 CLI: `dist/Shitsurae.app/Contents/Resources/shitsurae`

## ライセンス

MIT
