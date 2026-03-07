<p align="center">
  <img src="Shitsurae/AssetSources/icon.png" alt="Shitsurae" width="256" />
</p>

# Shitsurae

[English version (README.md)](README.md)

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

位置・サイズの単位は柔軟に指定可能：`%`（画面比率）、`pt`（論理座標）、`px`（物理ピクセル）、`r`（0.0〜1.0 の比率）。

### 2. キーボードファーストな操作

すべての操作をキーボードで完結できます。デフォルトショートカット：

| 操作 | デフォルト | 説明 |
|------|-----------|------|
| スロットフォーカス | `Cmd+1` 〜 `Cmd+9` | 番号を割り当てたウィンドウに直接フォーカス |
| 次のウィンドウ | `Cmd+Ctrl+J` | 現在 Space 内で次のウィンドウに巡回 |
| 前のウィンドウ | `Cmd+Ctrl+K` | 現在 Space 内で前のウィンドウに巡回 |
| スイッチャー | `Cmd+Tab` | ウィンドウスイッチャーを表示 |
| スナップ | 任意設定 | 左半分・右半分・最大化など、プリセット配置 |

すべてのショートカットは YAML で自由にカスタマイズ可能。特定アプリが前面にあるときだけ無効化する設定もできます（例：Discord の `Cmd+1` と競合しないように制御）。

### 3. 内蔵ウィンドウスイッチャー

`Cmd+Tab`（カスタマイズ可能）で起動する独自のスイッチャー：

- 現在 Space のウィンドウを優先表示
- 各候補に `a`, `s`, `d`, `f`, … のクイックキーが割り当てられ、1 打鍵で即時切替
- `acceptOnModifierRelease` 対応——修飾キーを離すだけで選択確定
- accept/cancel キー、クイックキー文字列、対象 Space の範囲をカスタマイズ可能

### 4. ウィンドウスナップ

プリセットによるウィンドウ配置操作：

- `leftHalf`・`rightHalf`・`topHalf`・`bottomHalf`
- `leftThird`・`centerThird`・`rightThird`
- `maximize`・`center`

任意のグローバルショートカットに割り当てられます。

### 5. メニューバー + GUI アプリ

Shitsurae は通常の macOS アプリとして起動し、メニューバーにも常駐します。

**メニューバー** — いつでもアクセス可能：
- 定義済みレイアウトの適用
- メインウィンドウを開く
- Preferences / Diagnostics
- 設定ディレクトリを開く
- 設定リロード

**メインウィンドウ** — サイドバー付きの GUI：
- 色分けされたスロットのレイアウトプレビュー
- ドライラン付きの配置操作
- ショートカット一覧
- 権限状態と診断情報

### 6. CLI と自動化

シェルスクリプトや自動化から同じ機能を利用できます。

```bash
shitsurae arrange <layout> --dry-run --json    # 実行計画の確認（変更なし）
shitsurae arrange <layout> --json              # レイアウト適用
shitsurae arrange <layout> --space 2 --json    # 特定 Space に適用
shitsurae layouts list                         # 定義済みレイアウト一覧
shitsurae validate --json                      # 設定ファイルの検証
shitsurae diagnostics --json                   # 診断情報
shitsurae window current --json                # 現在フォーカスウィンドウの情報
shitsurae window set --x 0% --y 0% --w 50% --h 100%   # 移動 + リサイズ
shitsurae focus --slot 1                       # スロット指定フォーカス
shitsurae focus --bundle-id com.apple.TextEdit  # アプリ指定フォーカス
shitsurae switcher list --json                 # スイッチャー候補一覧
```

`window move` / `window resize` / `window set` はセレクター未指定時、現在フォーカス中のウィンドウを対象にします。セレクター：`--window-id`（ウィンドウ指定）、`--bundle-id`（アプリ指定）、`--title`（`--bundle-id` と組み合わせ）。

### 7. マルチディスプレイ対応

- `primary` / `secondary` のロール指定、解像度条件でディスプレイをマッチ
- 同じ Space ID に複数の解像度別定義を書いておくと、一致した最初の定義が自動適用（first-match）
- MacBook 単体と外部モニター接続時で、設定を書き換えずに適切なレイアウトが選ばれる

### 8. 設定自動リロード

- 設定ディレクトリ内の `*.yml` / `*.yaml` をファイル名順で読み込み
- ファイル変更を監視し自動リロード
- 構文エラー時は直前の有効な設定を維持し、診断画面にエラー内容を表示

## 動作要件

- macOS 15（Sequoia）以降
- Accessibility 権限（必須）
- Screen Recording 権限（任意——スイッチャーのサムネイル表示を使う場合のみ）

通常運用で外部ネットワーク通信は不要です。

## インストール

### ソースからビルド

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

### 配布版の初回起動（Notarize なし）

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

### ショートカットのカスタマイズ

```yaml
shortcuts:
  # 前面アプリ単位で Cmd+1..9 だけの有効/無効を切り替え
  focusBySlotEnabledInApps:
    com.hnc.Discord: false
    com.tinyspeck.slackmacgap: false

  # Cmd+Ctrl+J / K の候補から除外
  cycleExcludedApps:
    - com.hnc.Discord

  # Cmd+Tab の候補から除外
  switcherExcludedApps:
    - com.tinyspeck.slackmacgap

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

## ライセンス

MIT
