---
name: shitsurae-release
description: Shitsurae のリリースを app-vX.Y.Z タグ、GitHub Releases の asset、Homebrew cask 更新導線まで一貫して進めるためのスキルです。ユーザーが「リリースしたい」「バージョンを切りたい」「GitHub Releases に公開したい」「brew cask を更新したい」「release workflow を確認したい」「release 失敗を調査したい」と依頼したときは、このスキルを使ってこの repo 内の version・asset・workflow 定義を根拠に Shitsurae 固有の手順で進めてください。
compatibility:
  os: macOS
  tools:
    - git
    - gh
    - swift
    - brew
---

# Shitsurae Release Skill

## 概要
このスキルは `shitsurae` の release フロー専用です。汎用的な GitHub Release 手順ではなく、以下の前提に固定されています。

- version の正本は `VERSION`
- release tag は `app-vX.Y.Z`
- release asset は `Shitsurae.app.tar.gz`
- Homebrew 配布の有無や dispatch 先は、この repo 内の workflow 定義から解決する

現状の Homebrew 配布物は未署名・未 notarize なので、release 後の確認や README 更新では quarantine を外す `xattr` 導線を維持してください。

## このスキルを使う場面
以下のような依頼ではこのスキルを使ってください。

- `shitsurae` をリリースしたい
- 新しい version を切りたい
- `app-v...` タグを作る、または確認したい
- `Shitsurae.app.tar.gz` を GitHub Releases に公開したい
- Homebrew cask の更新導線を確認したい
- release workflow や cask update の失敗原因を調べたい

署名や notarization の設計作業には使わず、ユーザーが明示的にその話題を出した場合だけ別作業として扱ってください。

## 最初に確認するファイル
release 関連の変更や検証に入る前に、最低限このファイルを確認してください。

- `VERSION`
- `Scripts/bump-version.sh`
- `Scripts/build-app-bundle.sh`
- `Scripts/create-release-asset.sh`
- `.github/workflows/release-app.yml`
- `README.md`
- `README.ja.md`

## 進め方

### 1. 対象 version を確定する
- `VERSION` を読み、前後の空白を除去する
- ユーザーが `patch` / `minor` / `major` のいずれかを指定した場合は、最初に `./Scripts/bump-version.sh <kind>` を実行して `VERSION` を更新する
- bump 後は `VERSION` を再読込して target version を確定する
- ユーザーが具体的な release version を指定した場合は `VERSION` と一致させる
- tag 形式は必ず `app-v<version>` を使う
- fallback の versioning や別名 tag は作らない
- semver bump は `major.minor.patch` 前提で扱う

### 2. preflight を取る
- この repo で `git status --short` を確認する
- 想定外の差分があれば、先にユーザーへ確認する
- release tag を push する前に、`.github/workflows/release-app.yml` を読んで Homebrew 関連の dispatch や secret 依存を確認する
- 以前の会話内容を前提にせず、今ある workflow とファイルを読む

### 3. release 入力をローカルで検証する
- `env -u LIBRARY_PATH swift test` を実行する
- release 準備または実行依頼なら `./Scripts/create-release-asset.sh` で asset を作る
- 生成した `.app` に `CFBundleShortVersionString` と `CFBundleVersion` が正しく入っていることを確認する
- cask や handoff 文書で具体的な SHA256 が必要なら、`Shitsurae.app.tar.gz` から計算する

### 4. release に出るメタデータと README を整える
- `README.md` と `README.ja.md` を現在の install flow に合わせる
- 未署名・未 notarize の間は `xattr` 案内を消さない
- Homebrew 導線の記述は、この repo 内で公開している install 手順と矛盾させない

### 5. commit と push の順序を守る
- この repo の変更を先に整理し、release 実行前に push 済みにする
- commit message は各 repo の既存 log に合わせる
- ユーザーが commit や release 実行を求めていない限り、勝手に commit はしない

### 6. release を実行する
ユーザーが実際の release を求めた場合は、次の順で進めます。

- この repo が push 済みであることを確認する
- この repo の対象 commit に `app-vX.Y.Z` tag を作る
- その tag を origin に push する
- `.github/workflows/release-app.yml` に GitHub Release と `Shitsurae.app.tar.gz` の upload を任せる
- Homebrew 関連の後続処理は workflow 定義どおりに実行させる

release asset 名や tag 形式を手で変えないでください。

### 7. remote 結果を確認する
`gh` が使えるなら `gh` を優先し、難しければ GitHub UI の確認ポイントをユーザーに伝えてください。

最低限、以下を確認してください。

- この repo の `release-app` workflow が成功している
- GitHub Release `app-vX.Y.Z` が存在する
- `Shitsurae.app.tar.gz` が release asset として添付されている
- Homebrew 更新が workflow に含まれるなら、その後続 job や dispatch 先の成功を確認する

### 8. 想定される smoke test
release 後に想定する利用者フローは以下です。

- `brew tap yuki-yano/shitsurae`
- `brew install --cask shitsurae`
- `xattr -dr com.apple.quarantine <Shitsurae.app の install path>`
- `open <Shitsurae.app の install path>`
- `shitsurae --help`

release asset がまだ remote に無い状態で `brew audit --online` や `brew install --cask` が 404 になるのは、pre-release 段階では想定内です。cask 構文エラーと誤認しないでください。

## 出力の順序
release 関連の報告は、原則として次の順でまとめてください。

1. `Preflight`
2. `Changes`
3. `Verification`
4. `Blockers` または `Next step`

dry-run や準備だけで止めた場合は、tag push と remote release を実行していないことを明記してください。

## この repo 固有のルール
- `VERSION` と `app-vX.Y.Z` を絶対にズラさない
- 未署名の間は Homebrew 向け `xattr` 案内を消さない
- tag push 前にローカル検証を優先する
- release failure 時は、まず workflow log を見てから修正方針を決める
