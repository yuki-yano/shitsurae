# Shitsurae

[English version (README.md)](README.md)

Shitsurae は、再現可能なウィンドウレイアウトを実現する macOS 向けワークスペース整列ツールです。  
理想の作業環境を YAML で定義し、1 コマンドで適用できます。

「Shitsurae（しつらえ）」という名前は、空間を目的に合わせて整える日本語の概念に由来しています。  
このプロジェクトは、その発想をデジタル作業空間に持ち込むものです。

## 解決する課題

- 毎朝のウィンドウ再配置を手作業で繰り返している
- 外部ディスプレイ接続/切断でレイアウトが崩れる
- アプリ・ウィンドウの切り替えが遅い
- 作業内容ごとに同じレイアウト作業を何度も繰り返す

## 主な機能

### 1. レイアウト一括適用（`arrange`）

- 必要なアプリを起動
- ウィンドウを対象 Space へ移動
- 指定フレームへ配置
- 必要に応じて初期フォーカスを設定

### 2. キーボード中心の操作

デフォルトショートカット:

- `Cmd+1` ... `Cmd+9`: スロットフォーカス
- `Cmd+Ctrl+J`: 次のウィンドウ
- `Cmd+Ctrl+K`: 前のウィンドウ
- `Cmd+Tab`: スイッチャー起動

すべて YAML でカスタマイズできます。

### 3. 内蔵スイッチャー

- ウィンドウ候補を表示
- クイックキーで 1 打鍵選択
- 現在 Space 優先表示に対応

### 4. メニューバー + Dock アプリ

- 通常の macOS アプリとして起動（Dock 表示あり）
- メニューバーから常時操作可能
- Preferences / Diagnostics をアプリ内から利用可能

### 5. CLI と自動化

シェルスクリプトやターミナル運用から、同じコア機能を利用できます。

### 6. マルチディスプレイ対応

- `primary` / `secondary` のロール指定
- 条件一致ベースのディスプレイ定義
- ディスプレイ条件の first-match で適用先を決定

### 7. 設定自動リロード

- 設定ディレクトリ内の `*.yml` / `*.yaml` をファイル名順で読み込み
- 設定変更を監視し自動リロード

## 動作要件

- macOS 15 以降
- Accessibility 権限（必須）
- Screen Recording 権限（サムネイル系オーバーレイ機能を使う場合のみ必須）

通常運用で外部ネットワーク通信は不要です。

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

## 配布版の初回起動（Notarize なし）

`.app` をそのまま配布してユーザーがダウンロードした場合、初回は quarantine を外して起動してください。

```bash
xattr -dr com.apple.quarantine Shitsurae.app
open Shitsurae.app
```

## 設定ディレクトリ

Shitsurae は次の順で設定ディレクトリを解決します。

1. `$XDG_CONFIG_HOME/shitsurae/`
2. `~/.config/shitsurae/`

サンプル設定:

- `samples/xdg-config-home/shitsurae/01-basic-layout.yaml`

## YAML Schema / LSP

YAML LSP の補完と validation を有効にするには、設定ファイルの先頭で schema を参照します。

```yaml
# yaml-language-server: $schema=https://raw.githubusercontent.com/yuki-yano/shitsurae/refs/heads/main/schemas/shitsurae-config.schema.json
```

## 主要コマンド

```bash
shitsurae validate --json
shitsurae layouts list
shitsurae arrange <layoutName> --dry-run --json
shitsurae arrange <layoutName> --json
shitsurae arrange <layoutName> --space 2 --json
shitsurae diagnostics --json
shitsurae window current --json
shitsurae switcher list --json
```

## Space Move Method

`executionPolicy.spaceMoveMethod` で既定の移動方式を指定し、`executionPolicy.spaceMoveMethodInApps` で bundle ID ごとに上書きできます。

```yaml
executionPolicy:
  spaceMoveMethod: drag
  spaceMoveMethodInApps:
    org.alacritty: displayRelay
```

指定できる値:

- `drag`: ウィンドウをドラッグしたまま macOS の desktop shortcut を送る
- `displayRelay`: マルチディスプレイの `perDisplay` 環境で、いったん別 display に退避して target space を切り替えてから戻す

## Chromium 系ブラウザの profile 指定

`com.google.Chrome` / `com.brave.Browser` / `com.microsoft.edgemac` / `org.chromium.Chromium` では、`match.profile` で profile ごとのウィンドウを指定できます。

```yaml
layouts:
  browser:
    spaces:
      - spaceID: 1
        windows:
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

- `profile` は Chromium の profile directory 名です。表示名ではありません。
- 典型的な値は `Default`, `Profile 1`, `Profile 2` です。
- `launch: true` の場合、Shitsurae は `--profile-directory=<profile> --new-window` 付きで起動し、その直後に増えたウィンドウを優先して配置します。
- `shitsurae window current --json` の `profile` に、判定できた profile directory 名が出ます。

## スロットフォーカスのアプリ別制御 / Fallback

`Cmd+1 ... Cmd+9` の挙動は `shortcuts` で制御できます。

```yaml
shortcuts:
  # runtime state に slot が無い場合の slot->app fallback を有効化
  focusBySlotFallbackEnabled: true

  # 前面アプリ単位で Cmd+1..9 だけの有効/無効を切り替え（true=有効, false=無効）
  focusBySlotEnabledInApps:
    com.hnc.Discord: false
    com.tinyspeck.slackmacgap: false

  # Cmd+Ctrl+J / Cmd+Ctrl+K の候補から除外
  cycleExcludedApps:
    - com.hnc.Discord

  # Cmd+Tab の候補から除外
  switcherExcludedApps:
    - com.tinyspeck.slackmacgap
```

slot の対象が発火時点で具体的に存在しない場合は、`Cmd+1 ... Cmd+9` は Shitsurae で消費せず前面アプリ / macOS にそのまま流れます。

`disabledInApps` も引き続き使えますが、`Cmd+1 ... Cmd+9` だけをアプリ別に pass-through したい場合は `focusBySlotEnabledInApps` のほうが用途に合っています。
