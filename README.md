# esepad

iPhone を横に寝かせて、画面ぜんぶを Mac のトラックパッドにする。縦に持てば、マウスの形になる。

## English summary

Lay your iPhone flat in landscape and the whole screen becomes a trackpad for your Mac: one-finger move, tap to click, two-finger scroll with momentum, three-finger desktop swipes. Hold it in portrait and it becomes a mouse. Haptics on clicks and drags; the screen can be tinted to match the MacBook next to it.

- **Bluetooth only.** The iPhone and the Mac talk over Bluetooth LE (GATT or L2CAP). Nothing is sent over the network, and there is no server or account.
- **Pairing.** The first time, you choose "pair a new iPhone" in the Mac menu bar; the Mac shows a 6-digit number and you type it on the iPhone. Then a person has to press "Connect" in a window on the Mac. After that, every session is authenticated with a stored key and the input is encrypted (ChaCha20-Poly1305). The details, and what this does not protect against, are in "つなぐ相手を限定する仕組み" below (Japanese).
- **What you need.** A Mac (macOS 14+), an iPhone (iOS 17+) and Xcode 27+. There is no prebuilt binary: you build both apps yourself and sign them with your own Apple ID (see "作る" below). The Mac app asks for Bluetooth and Accessibility permissions.
- **Limits.** Three-finger desktop swipes use an undocumented mechanism that may stop working in a future macOS (a keyboard-shortcut fallback is in the menu). It cannot be on the Mac App Store (the sandbox forbids controlling other apps). One iPhone at a time. No forward secrecy for the session key. The UI and most of this README are in Japanese only.

Lightly inspired by AimMac (Coolerwave, MIT); no code shared. Licensed under MIT; credits in `NOTICE.md`.

---

## 日本語の説明

- 画面はのっぺりの単色（シルバー／スターライト／スペースグレイ／ミッドナイトから選ぶ）。隣に置く MacBook と同じ色にすると、Mac の一部に見える。色は、つなぐ画面の下の 4 つの丸か、4 本指で 0.8 秒押さえて開く確かめの画面で選ぶ（触ったらすぐ変わる。つないだ Mac ごとに iPhone が覚える）。最初の色は Mac が機種と筐体の色を教えて決める（確かめた組だけ。知らない Mac はスペースグレイから）。使っている間は画面は消えない
- **横置き＝トラックパッド**: 1 本指で移動 / タップでクリック（軽く震える）/ 2 本指タップで右クリック / 2 本指でスクロール（慣性つき）
- **ドラッグは 2 通り**（縦でも同じ）: 長押ししてから滑らせる、または**トン→すぐ置いて離さずに滑らせる**（Mac のトラックパッドのドラッグと同じ。1 回目のトンはその場でクリックになり、2 回目を滑らせずに離せばダブルクリック）。入る時に強く 2 回、離す時に軽く震える
- **3 本指**: 横に動かすと、デスクトップが指についてくる（本物のトラックパッドと同じ。離した位置と速さで「切り替わる／戻る」が決まる）。上に動かすと Mission Control
- **縦置き＝マウスの形**: 向きで自動で切り替わる（設定は無い。机に寝かせて向きが取れない時は、最後の向きのまま）。面ぜんぶで 1 本指のなぞりがカーソルになる。
  - 面ぜんぶを縦のまん中で左右に分ける（置いたマウスの左右のボタン）。左半分のトン＝左クリック、右半分のトン＝右クリック（右は強めに震える）。置いてすぐ離した時だけ。なぞった時は、どちら側でも面ぜんぶでカーソルが動く
  - トン→滑らせるドラッグは、左右どちらで始めても左ボタンのドラッグ。トントンはダブルクリック（左も右も）。2 本指のトンは、横置きと同じ右クリック
  - 右端の細い帯（30pt）で始めて縦になぞると、1 本指でスクロール（片手の親指用）。右端で始めても横に動かせばカーソル（右端の帯のトンは、右半分なので右クリック）
  - 2 本指のスクロール・タップ・長押し・トン→滑らせるドラッグは、横置きと同じ
  - 画面には、まん中にごく薄い縦の線が 1 本（文字なし）。トンした側が、一瞬だけ薄く光る
- 速さは Mac のメニューバーで決める。Mac の「軌跡の速さ」の最大より上まで出せる。加速はオン／オフ
- スクロールは本物のトラックパッドと同じ形のイベント（ジェスチャーつき）で出す。向きは Mac のナチュラルスクロールの設定に合わせ、メニューで逆にもできる
- 3 本指のスワイプは本物のジェスチャーとして出せる（非公開の仕組み。将来の macOS で効かなくなったら、メニューで「キーボードの近道（Control+矢印）」に切り替える。近道の時は、離した時に 1 回だけ切り替わる）
- 4 本指で 0.8 秒押さえると、通信の確かめ（往復の時間、GATT / L2CAP の切り替え、面の色）が開く
- 通信は Bluetooth だけ。ネットには何も送らない
- アイコン: 指でなぞった e。素材と選ばれなかった 2 案は `design/icon/`

## 作り

| 場所 | 中身 |
|---|---|
| `Packages/EsepadCore` | 画面に依存しない部分。通信の形・暗号・ペアリング・指の判定・速さの計算。`swift test` で固めてある |
| `iOS/` | iPhone アプリ（SwiftUI + 指を受ける UIKit の View） |
| `Mac/` | Mac のメニューバーアプリ（CoreBluetooth で受けて、CGEvent でカーソルを動かす） |

## つなぐ相手を限定する仕組み

Mac はアクセシビリティの許可でカーソルを動かす。つなぐ相手を絞る仕組みは次のとおり。守れるものと守れないものを分けて書く。

1. **初回だけ**、Mac のメニューバーで「新しい iPhone をつなぐ…」を選ぶ。選んだ時から 120 秒だけ受け付ける（入口はこのメニューだけで、外からは開けない）。
2. iPhone で Mac を選ぶと、Mac に 6 桁の番号が出る。iPhone に打つ。
3. やり取りの順は、iPhone が公開鍵の「約束（ハッシュ）」を先に出す → Mac が公開鍵を出す → iPhone が公開鍵を明かす。約束を出すのは iPhone だけで、Mac は出さない。6 桁は、両方の公開鍵と iPhone の乱数から決まる。
4. **iPhone 側の確かめ**: 打った番号を、iPhone が自分の手元の値と照らす。途中に割り込んで公開鍵をすり替えた第三者がいると、Mac に出る番号と iPhone の期待する番号がずれて、iPhone は確認を送らない。打ち間違えは 3 回まで（この回数は iPhone の手元だけの制限で、Mac は知らない）。
5. **Mac 側の確かめ（番号）**: 確認の鍵に、Mac が画面に出した 6 桁を混ぜている。番号なし、またはずれた番号で作った確認は、Mac は開けずに断り、その 1 回で受け付けをやめる。
6. **Mac 側の確かめ（人）**: 番号の合った確認が届くと、Mac の窓に「自分の iPhone に、この番号を打ち終わりましたか？」という問いと番号（123 456 のような 6 桁）が大きく出て、「つなぐ」「やめる」の 2 つが出る（確認が届くまでは、番号だけでボタンは出ない）。**人が「つなぐ」を押した時だけ**、Mac は iPhone を覚える（キーチェーンに保存。保存できなかったら、つながったことにしない）。「やめる」、窓の ✕、120 秒のどれかで窓が閉じたら、待っていた相手は捨てられる。承認を待っている間に 2 つ目の確認が来たら、最初の 1 つだけ受けて、窓を閉じる。「つなぐ」は Return では押せない。
7. iPhone は、Mac の完了を開けた時だけ覚える（完了の鍵にも番号が混ざっている。iPhone のキーチェーンに保存）。キーチェーンを読めなかった時は、空から始めて元の鍵を上書きすることはしない。
8. 以降は、つなぐたびに挑戦と応答（その接続だけの鍵）で相手を確かめ、操作は暗号化と改ざん検知つきで送る（ChaCha20-Poly1305、カウンターで再生を拒否）。覚えていない端末には、確認のダイアログも出さずに断る（Mac 側の Bluetooth の特性に「暗号化必須」を付けていないので、OS のペアリング確認が出ない。`Mac/Sources/MacTransport.swift` の特性の定義）。
9. 受け付けをやめる条件は、120 秒たつ、「やめる」、公開鍵の明かし方が約束と合わない失敗が通算 3 回、確認の鍵が合わない 1 回、承認待ちの間の 2 つ目の確認。形が不正なだけの約束は数えない。

平文で流れるもの: 挨拶（この iPhone の ID 8 バイトと乱数）、挑戦、断りの返事、ペアリング中の公開鍵。L2CAP のリンク自体も暗号化していない（中身の操作は上のとおり暗号化している）。Mac の Bluetooth 広告名は、Mac の名前ではなく固定の `esepad`。

**6 桁だけでは Mac は守れない**: 6 桁は公開鍵と乱数だけから決まるので、Mac とペアリングの通信を自分で回す機器（近くの攻撃者、途中に割り込む第三者）は、画面を見なくても番号を計算でき、番号の合った確認を作れる。Mac は番号だけでは、それが本物の iPhone か見分けられない。そこで、確認が合っても、Mac の人が窓で「つなぐ」を押すまで覚えない（手順 6）。攻撃者が窓の間に先につないでも、人は自分の iPhone にその番号を打っていないので、「やめる」を押せば捨てられる。人が「つなぐ」を押す前に、自分の iPhone に自分でその番号を打ち終えたかを確かめることが、この手順の守りの中身。打っていないのに押すと、攻撃者を覚える。

## 作る

必要なもの: Xcode 27 以降、Mac（macOS 14 以降）、iPhone（iOS 17 以降）。

```bash
python3 scripts/generate_xcodeproj.py   # esepad.xcodeproj を作り直す（ふだんは不要）
cd Packages/EsepadCore && swift test    # 単体テスト
```

自分の Apple ID で署名するには、`Config/Local.xcconfig`（git には入らない）に 2 行書く。

```
BUNDLE_ID_PREFIX = com.yourname
DEVELOPMENT_TEAM = ABCDE12345
```

Xcode で `esepad`（iPhone）と `EsepadMac`（Mac）をそれぞれ実行する。Mac 側は最初に **Bluetooth** と **アクセシビリティ**（システム設定 > プライバシーとセキュリティ）の許可を求める。開発用の署名が毎回変わる（ad-hoc）と、再ビルドのたびにアクセシビリティとキーチェーンの許可を聞き直されることがある。

## 通信の速さ

指の動きは、詰まっても足し合わせて送る（1 ミリも失わない）。クリックなどは順番どおりに必ず送る。
送り方は 2 つ。GATT の write without response（初期値）と、L2CAP チャンネル。iPhone が Central の時、接続間隔は iOS が決めるので、アプリでできるのは L2CAP を使うことと、Mac 側から最短を頼むことまで。
どちらが速いかは、確かめの画面の往復時間で見る（数字は端末によるので、README には書かない）。

## 署名と TestFlight

```bash
./scripts/build-mac.sh install        # Mac を開発用の証明書で署名して /Applications へ（再ビルドしても許可が残る）
./scripts/archive-ios.sh 3            # iPhone の ipa を作る（3 はビルド番号）。App Store Connect への登録・アップロードは別
./scripts/archive-ios.sh 3 --no-sign  # 署名なしでアーカイブだけ（ビルドが通るかの確認）
```

## いまの限界

- 実機の遅れ・指の判定のしきい値・スクロールの向きは、実際の端末で調整が要る（Mac のメニューで「スクロールの向きを逆にする」を用意してある）
- 本物の 3 本指ジェスチャーのうち、Mission Control（上）の向きは確かめていない。既定は「左右は本物、上は近道」
- 面の色の値（`SurfaceColor.rgb`）は仮。筐体の色の表（`MacInfo.knownHousings`）は確かめた 1 組（MacBookPro18,4）だけ。新しい Mac は、実機で見て確かめてから足す
- 3 本指の「指についてくる」動きは、実機で確かめる段階。指が何 pt 動くとデスクトップ 1 枚ぶんか（`DockSwipeDriver.fullTravel`）、切り替える境目（`fluidCommit`・`flickSpeed`）は、触って決める値
- Mac App Store には置けない（サンドボックスの中ではほかのアプリを操作できない）
- 複数の iPhone を同時に使う想定はしていない
- ペアリングの窓: 公開鍵の約束だけ送って黙る機器は、15 秒で持ち主を手放される（次の機器が入れる）。ただし、公開まで進んで番号の入力で黙る機器は、窓の 120 秒まで窓を占有できる。窓の 120 秒は、時刻の変更に影響されない時計（スリープ中も進む）で数える
- この iPhone の ID（8 バイト）は挨拶で平文に流れる。同じ iPhone を、Bluetooth のアドレスが変わっても追いかけられる
- セッション鍵はマスター鍵と接続ごとの乱数から作る。マスター鍵が漏れると、録音しておいた過去の通信を読める（前方秘匿性はない）
- 偽の機器が、保存した Mac と同じ名前を広告して、iPhone を妨害することはできる（鍵は消えない）。覚えている Mac への挨拶で断られた時、iPhone は 3 回まで画面に出さずにつなぎ直し、それでも断られたら「つなげない」などの画面を出す。認証のあとに平文で届いた断りは無視する

## ライセンス

MIT（`LICENSE`）。デスクトップ切り替えの組み立ては iss（0BSD）、スクロールのイベントの形は LinearMouse（MIT）を参考にしている。詳しくは `NOTICE.md`。

---

esepad は BECKY（[beckyexists.com](https://beckyexists.com)）が作っています。
