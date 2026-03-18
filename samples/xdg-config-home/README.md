# XDG Config Samples

`$XDG_CONFIG_HOME/shitsurae/` へ配置して使う運用サンプル。

## 01-basic-layout.yaml

- 実行コマンド: `shitsurae arrange work --dry-run --json`
- 期待終了コード: `0`

## 02-chromium-profile.yaml

- 実行コマンド: `shitsurae arrange browser --dry-run --json`
- 期待終了コード: `0`

## shitsurae/virtual/01-virtual-space-mode.yaml

- 実行コマンド: `shitsurae arrange virtualWork --dry-run --json`
- bootstrap: `shitsurae arrange virtualWork --state-only --space 1 --json`
- workspace 移動: `shitsurae window workspace 2 --json`
- 期待終了コード: `0`
